#!/usr/bin/ruby

module Angular::AsfRosterServices

  # Since Angular.JS doesn't allow circular dependencies, keep the canonical
  # rosters of each class in a separate place so that they can be referenced
  # anywhere.
  class Roster
    COMMITTERS = {}
    PMCS = {}
  end

  # Instances of this class represent a Committer from LDAP.
  class Committer
    @@list = Roster::COMMITTERS

    def self.load(ldap)
      angular.copy({}, @@list)
      for uid in ldap.committers
        @@list[uid] = Committer.new(ldap.committers[uid])
      end
    end

    def self.find(id)
      return @@list[id]
    end

    def initialize(ldap)
      angular.copy ldap, self
    end

    def link
      return "committer/#{self.cn}"
    end

    def pmcs
      result = []
      for name in Roster::PMCS
        pmc = Roster::PMCS[name]
        result << pmc if pmc.memberUid.include? self.uid 
      end
      result
    end
  end

  # Instances of this class represent a PMC from LDAP, augmented with
  # information from committee-info.txt.
  class PMC
    @@list = Roster::PMCS

    def self.load(ldap)
      for pmc in ldap.pmcs
        @@list[pmc] = PMC.new(ldap.pmcs[pmc])
      end
      @@groups = ldap.groups
    end

    def initialize(ldap)
      angular.copy ldap, self
      @members = []
      @committers = []
      @@list[self.cn] = self
    end

    def display_name
      info = INFO.get(self.cn)
      return info ? info.display_name : self.cn
    end

    def link
      return "committee/#{self.cn}"
    end

    def chair
      info = INFO.get(self.cn)
      return Committer.find(info.chair) if info
    end

    def members
      @members.clear()
      info = INFO.get(self.cn)

      # add PMC members from comittee-info.txt
      if info
        info.memberUid.each do |uid|
          person = Committer.find(uid)
          @members << person if person
        end
      end

      # add unique PMC members from LDAP
      self.memberUid.each do |uid|
        person = Committer.find(uid)
        @members << person if person and not @members.include? person
      end

      @members
    end

    def committers
      self.members if @members.empty?
      members = @members
      @committers.clear()
      group = @@groups[self.cn]

      # add members from LDAP group of the same name
      if group
        group.memberUid.each do |uid|
          person = Committer.find(uid)
          @committers << person if person and not members.include? person
        end
      end

      @committers
    end
  end

  # merge data from multiple sources
  class Merge
    @@committers = nil
    @@pmcs = nil
    @@info = nil
    @@ldap_groups = nil
    @@groups = {}
    @@services = nil
    @@count = 0

    def self.ldap(ldap)
      @@committers = ldap.committers
      @@pmcs = ldap.pmcs
      @@services = ldap.services
      @@ldap_groups = ldap.groups
      self.merge()
    end

    def self.info(info)
      @@info = info
      self.merge()
    end

    def self.merge()
      @@count += 1
      return unless @@committers
      if @@info
        committers = @@committers

        for group in @@ldap_groups
          next if %w(committers).include? group or @@pmcs[group]
          @@ldap_groups[group].source = 'LDAP group'
          @@groups[group] = @@ldap_groups[group]
        end

        for group in @@services
          next if %w(apldap infrastructure-root).include? group
          if group == 'infrastructure'
            group  = @@services.infrastructure
            group.members ||= []
            group.members.clear()
            group.memberUid.each do |uid|
              person = committers[uid]
              group.members << person if person
            end
          else
            @@services[group].source = 'LDAP service'
            @@groups[group] = @@services[group]
          end
        end

        for group in @@info
          next if @@pmcs[group] or @@info[group].memberUid.empty?
          @@info[group].source = 'committee-info.txt'
          @@groups[group] = @@info[group]
        end

        for name in @@groups
          group = @@groups[name]
          group.link = "group/#{name}"
        end
      end
    end

    def self.groups()
      return @@groups 
    end

    def self.count
      return @@count
    end
  end

  class LDAP
    @@fetching = false

    @@index = {
      services: {},
      committers: {},
      pmcs: {},
      groups: {},
      members: []
    }

    def self.fetch_twice(url, &update)
      if_cached = {"Cache-Control" => "only-if-cached"}
      $http.get(url, cache: false, headers: if_cached).success { |result|
        update(result)
      }.finally {
        setTimeout 0 do
          $http.get(url, cache: false).success do |result, status|
            update(result) unless status == 304
          end
        end
      }
    end

    def self.get()
      unless @@fetching
        @@fetching = true
        self.fetch_twice 'json/ldap' do |result|
          # add in links
          for group in result.groups
            result.groups[group].link = "group/#{group}"
          end

          for group in result.services
            result.services[group].link = "group/#{group}"
          end

          Committer.load(@@index)
          PMC.load(@@index)

          # copy to class variables
          angular.copy result.services, @@index.services
          angular.copy result.committers, @@index.committers
          angular.copy result.pmcs, @@index.pmcs
          angular.copy result.groups, @@index.groups
          angular.copy result.groups.member.memberUid, @@index.members

          # merge with other sources
          Merge.ldap(@@index)
        end
      end

      return @@index
    end

    def self.committers
      return self.get().committers
    end

    def self.members
      return self.get().members
    end

    def self.services
      return self.get().services
    end

    def self.pmcs
      return self.get().pmcs
    end

    def self.groups
      return self.get().groups
    end

    def self.group(name)
      return self.get().groups[name]
    end
  end

  class INFO
    @@info = {}

    def self.get(name)
      unless @@fetching
        @@fetching = true
        $http.get('json/info').success do |result|
          for pmc in result
            result[pmc].cn = pmc
          end

          angular.copy result, @@info
          Merge.info(@@info)
        end
      end

      if name
        return @@info[name]
      else
        return @@info
      end
    end
  end
end
