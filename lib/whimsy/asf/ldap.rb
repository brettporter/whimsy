require 'wunderbar'
require 'ldap'
require 'weakref'
require 'net/http'
require 'base64'

module ASF
  module LDAP
     # https://www.pingmybox.com/dashboard?location=304
     # https://github.com/apache/infrastructure-puppet/blob/deployment/data/common.yaml (ldapserver::slapd_peers)
    HOSTS = %w(
      ldaps://ldap1-us-west.apache.org:636
      ldaps://ldap1-eu-central.apache.org:636
      ldaps://ldap1-lw-us.apache.org:636
      ldaps://ldap2-us-west.apache.org:636
      ldaps://snappy5.apache.org:636
      ldaps://ldap2-lw-us.apache.org:636
    )

    # fetch configuration from apache/infrastructure-puppet
    def self.puppet_config
      return @puppet if @puppet
      file = '/apache/infrastructure-puppet/deployment/data/common.yaml'
      http = Net::HTTP.new('raw.githubusercontent.com', 443)
      http.use_ssl = true
      @puppet = YAML.load(http.request(Net::HTTP::Get.new(file)).body)
    end

    # extract the ldapcert from the puppet configuration
    def self.puppet_cert
      puppet_config['ldapclient::ldapcert']
    end

    # extract the ldap servers from the puppet configuration
    def self.puppet_ldapservers
      puppet_config['ldapserver::slapd_peers'].values.
        map {|host| "ldaps://#{host}:636"}
    rescue
      nil
    end

    # connect to LDAP
    def self.connect
      hosts.shuffle.each do |host|
        Wunderbar.info "Connecting to LDAP server: #{host}"

        begin
          # request connection
          uri = URI.parse(host)
          if uri.scheme == 'ldaps'
            ldap = ::LDAP::SSLConn.new(uri.host, uri.port)
          else
            ldap = ::LDAP::Conn.new(uri.host, uri.port)
          end

          # test the connection
          ldap.bind

          # save the host
          @host = host

          return ldap
        rescue ::LDAP::ResultError => re
          Wunderbar.error "Error connecting to LDAP server #{host}: " +
            re.message
        end

        return nil
      end
    end
  end

  # backwards compatibility for tools that called this interface, and
  # a part of the refresh strategy (something that should be revisited
  # with WeakReferences instead).
  def self.init_ldap
    return @ldap if @ldap
    @mtime = Time.now
    @ldap = ASF::LDAP.connect
  end

  # determine where ldap.conf resides
  if Dir.exist? '/etc/openldap'
    ETCLDAP = '/etc/openldap'
  else
    ETCLDAP = '/etc/ldap'
  end

  def self.ldap
    @ldap || self.init_ldap
  end

  # search with a scope of one
  def self.search_one(base, filter, attrs=nil)
    init_ldap unless defined? @ldap
    return [] unless @ldap

    Wunderbar.info "ldapsearch -x -LLL -b #{base} -s one #{filter} " +
      "#{[attrs].flatten.join(' ')}"
    
    begin
      result = @ldap.search2(base, ::LDAP::LDAP_SCOPE_ONELEVEL, filter, attrs)
    rescue
      result = []
    end

    result.map! {|hash| hash[attrs]} if String === attrs

    result
  end

  def self.refresh(symbol)
    if not @mtime or Time.now - @mtime > 300.0
      @mtime = Time.now
    end

    if instance_variable_get("#{symbol}_mtime") != @mtime
      instance_variable_set("#{symbol}_mtime", @mtime)
      instance_variable_set(symbol, nil)
    end
  end

  def self.pmc_chairs
    refresh(:@pmc_chairs)
    @pmc_chairs ||= Service.find('pmc-chairs').members
  end

  def self.committers
    refresh(:@committers)
    @committers ||= Group.find('committers').members
  end

  def self.members
    refresh(:@members)
    @members ||= Group.find('member').members
  end

  class Base
    attr_reader :name

    def self.base
      @base
    end

    def base
      self.class.base
    end

    def self.collection
      @collection ||= Hash.new
    end

    def self.[] name
      new(name)
    end

    def self.find name
      new(name)
    end

    def self.new name
      begin
        object = collection[name]
        return object.reference if object and object.weakref_alive?
      rescue
      end

      super
    end

    def initialize name
      self.class.collection[name] = WeakRef.new(self)
      @name = name
    end

    def reference
      self
    end

    unless Object.respond_to? :id
      def id
        @name
      end
    end
  end

  class LazyHash < Hash
    def initialize(&initializer)
      @initializer = initializer
    end

    def load
     return unless @initializer
     merge! @initializer.call || {}
     @initializer = super
    end

    def [](key)
      result = super
      if not result and not keys.include? key and @initializer
        merge! @initializer.call || {}
        @initializer = nil
        result = super
      end
      result
    end
  end

  class Person < Base
    @base = 'ou=people,dc=apache,dc=org'

    def self.list(filter='uid=*')
      ASF.search_one(base, filter, 'uid').flatten.map {|uid| find(uid)}
    end

    # pre-fetch a given attribute, for a given list of people
    def self.preload(attributes, people={})
      list = Hash.new {|hash, name| hash[name] = find(name)}

      attributes = [attributes].flatten

      if people.empty?
        filter = "(|#{attributes.map {|attribute| "(#{attribute}=*)"}.join})"
      else
        filter = "(|#{people.map {|person| "(uid=#{person.name})"}.join})"
      end
      
      zero = Hash[attributes.map {|attribute| [attribute,nil]}]

      data = ASF.search_one(base, filter, attributes + ['uid'])
      data = Hash[data.map! {|hash| [list[hash['uid'].first], hash]}]
      data.each {|person, hash| person.attrs.merge!(zero.merge(hash))}

      if people.empty?
        (list.values - data.keys).each do |person|
          person.attrs.merge! zero
        end
      end

      list.values
    end

    def attrs
      @attrs ||= LazyHash.new {ASF.search_one(base, "uid=#{name}").first}
    end

    def public_name
      return icla.name if icla
      cn = [attrs['cn']].flatten.first
      cn.force_encoding('utf-8') if cn.respond_to? :force_encoding
      return cn if cn
      ASF.search_archive_by_id(name)
    end

    def asf_member?
      ASF::Member.status[name] or ASF.members.include? self
    end

    def asf_officer_or_member?
      asf_member? or ASF.pmc_chairs.include? self
    end

    def asf_committer?
       ASF::Group.new('committers').include? self
    end

    def banned?
      not attrs['loginShell'] or attrs['loginShell'].include? "/usr/bin/false"
    end

    def mail
      attrs['mail'] || []
    end

    def alt_email
      attrs['asf-altEmail'] || []
    end

    def pgp_key_fingerprints
      attrs['asf-pgpKeyFingerprint']
    end

    def urls
      attrs['asf-personalURL'] || []
    end

    def committees
      Committee.list("member=uid=#{name},#{base}")
    end

    def groups
      Group.list("memberUid=#{name}")
    end

    def dn
      value = attrs['dn']
      value.first if Array === value
    end

    def method_missing(name, *args)
      if name.to_s.end_with? '=' and args.length == 1
        return modify(name.to_s[0..-2], args)
      end

      return super unless args.empty?
      result = self.attrs[name.to_s]
      return super unless result

      if result.empty?
        return nil
      else
        result.map! do |value|
          value = value.dup.force_encoding('utf-8') if String === value
          value
        end

        if result.length == 1
          result.first
        else
          result
        end
      end
    end

    def modify(attr, value)
      value = Array(value) unless Hash === value
      mod = ::LDAP::Mod.new(::LDAP::LDAP_MOD_REPLACE, attr.to_s, value)
      ASF.ldap.modify(self.dn, [mod])
      attrs[attr.to_s] = value
    end
  end

  class Group < Base
    @base = 'ou=groups,dc=apache,dc=org'

    def self.list(filter='cn=*')
      ASF.search_one(base, filter, 'cn').flatten.map {|cn| find(cn)}
    end

    def include?(person)
      filter = "(&(cn=#{name})(memberUid=#{person.name}))"
      if ASF.search_one(base, filter, 'cn').empty?
        return false
      else
        return true
      end
    end

    def members
      ASF.search_one(base, "cn=#{name}", 'memberUid').flatten.
        map {|uid| Person.find(uid)}
    end
  end

  class Committee < Base
    @base = 'ou=pmc,ou=committees,ou=groups,dc=apache,dc=org'

    def self.list(filter='cn=*')
      ASF.search_one(base, filter, 'cn').flatten.map {|cn| Committee.find(cn)}
    end

    def members
      ASF.search_one(base, "cn=#{name}", 'member').flatten.
        map {|uid| Person.find uid[/uid=(.*?),/,1]}
    end

    def dn
      @dn ||= ASF.search_one(base, "cn=#{name}", 'dn').first.first
    end
  end

  class Service < Base
    @base = 'ou=groups,ou=services,dc=apache,dc=org'

    def self.list(filter='cn=*')
      ASF.search_one(base, filter, 'cn').flatten
    end

    def dn
      "cn=#{id},#{self.class.base}"
    end

    def members
      ASF.search_one(base, "cn=#{name}", 'member').flatten.
        map {|uid| Person.find uid[/uid=(.*?),/,1]}
    end

    def remove(people)
      people = Array(people).map(&:dn)
      mod = ::LDAP::Mod.new(::LDAP::LDAP_MOD_DELETE, 'member', people)
      ASF.ldap.modify(self.dn, [mod])
    end

    def add(people)
      people = Array(people).map(&:dn)
      mod = ::LDAP::Mod.new(::LDAP::LDAP_MOD_ADD, 'member', people)
      ASF.ldap.modify(self.dn, [mod])
    end
  end

  module LDAP
    def self.bind(user, password, &block)
      dn = ASF::Person.new(user).dn
      ASF.ldap.unbind rescue nil
      if block
        ASF.ldap.bind(dn, password, &block)
        ASF.init_ldap
      else
        ASF.ldap.bind(dn, password)
      end
    end

    # validate HTTP authorization, and optionally invoke a block bound to
    # that user.
    def self.http_auth(string, &block)
      auth = Base64.decode64(string[/Basic (.*)/, 1] || '')
      user, password = auth.split(':', 2)
      return unless password

      if block
        self.bind(user, password, &block)
      else
        begin
          ASF::LDAP.bind(user, password) {}
          return ASF::Person.new(user)
        rescue ::LDAP::ResultError
          return nil
        end
      end
    end

    # determine what LDAP hosts are available
    def self.hosts
      # try whimsy config
      hosts = Array(ASF::Config.get(:ldap))

      # check system configuration
      if hosts.empty?
        conf = "#{ETCLDAP}/ldap.conf"
        if File.exist? conf
          uris = File.read(conf)[/^uri\s+(.*)/i, 1].to_s
          hosts = uris.scan(/ldaps?:\/\/\S+?:\d+/)
        end
      end

      # if all else fails, use default list
      hosts = ASF::LDAP::HOSTS if hosts.empty?

      hosts
    end

    # select LDAP host
    def self.host
      @host ||= hosts.sample
    end

    # query and extract cert from openssl output
    def self.extract_cert
      host = LDAP.host[%r{//(.*?)(/|$)}, 1]
      puts ['openssl', 's_client', '-connect', host, '-showcerts'].join(' ')
      out, err, rc = Open3.capture3 'openssl', 's_client',
        '-connect', host, '-showcerts'
      out[/^-+BEGIN.*?\n-+END[^\n]+\n/m]
    end

    # update /etc/ldap.conf. Usage:
    #
    #   sudo ruby -r whimsy/asf -e "ASF::LDAP.configure"
    #
    def self.configure
      cert = Dir["#{ETCLDAP}/asf*-ldap-client.pem"].first

      # verify/obtain/write the cert
      if not cert
        cert = "#{ETCLDAP}/asf-ldap-client.pem"
        File.write cert, ASF::LDAP.puppet_cert || self.extract_cert
      end

      # read the current configuration file
      ldap_conf = "#{ETCLDAP}/ldap.conf"
      content = File.read(ldap_conf)

      # ensure that the right cert is used
      unless content =~ /asf.*-ldap-client\.pem/
        content.gsub!(/^TLS_CACERT/i, '# TLS_CACERT')
        content += "TLS_CACERT #{ETCLDAP}/asf-ldap-client.pem\n"
      end

      # provide the URIs of the ldap hosts
      content.gsub!(/^URI/, '# URI')
      content += "uri \n" unless content =~ /^uri /
      content[/uri (.*)\n/, 1] = hosts.join(' ')

      # verify/set the base
      unless content.include? 'base dc=apache'
        content.gsub!(/^BASE/i, '# BASE')
        content += "base dc=apache,dc=org\n"
      end

      # ensure TLS_REQCERT is allow (Mac OS/X only)
      if ETCLDAP.include? 'openldap' and not content.include? 'REQCERT allow'
        content.gsub!(/^TLS_REQCERT/i, '# TLS_REQCERT')
        content += "TLS_REQCERT allow\n"
      end

      # write the configuration if there were any changes
      File.write(ldap_conf, content) unless content == File.read(ldap_conf)
    end
  end
end
