#!/usr/bin/ruby
Camping.goes :Nomic

module Nomic
  include Camping::Session

  module Models
    class Rule < Base
      has_many :votes
    end

    class Vote < Base
      belongs_to :rule
      belongs_to :user
    end

    class User < Base
      has_many :votes
    end

    class CreateNomic < V 1
      def self.up
        create_table :nomic_rules do |t|
          t.column :name,   :string, :null => false
          t.column :date,   :time,   :null => false
          t.column :code,   :string, :null => false
          t.column :status, :string, :null => false
        end

        create_table :nomic_votes do |t|
          t.column :rule_id, :int,  :null => false
          t.column :user_id, :int,  :null => false
        end

        create_table :nomic_users do |t|
          t.column :name, :string, :null => false, :limit => 255
          t.column :password, :string, :null => false, :limit => 255
          t.column :points, :integer, :null => false, :default => 0
        end
      end
    end
  end

  module Controllers
    class Root < R '/', '/rule'
      def get
        @rules = Rule.find :all, :limit => 10, :order => "date DESC", 
                           :include => :votes, 
                           :conditions => ['status = ?', 'pending']
        render :index
      end
    end

    class ViewRule < R '/rule/(\d+)'
      def get id
        @rule = Rule.find id
        render :rule
      end
    end

    class NewRule < R '/rule/new'
      def get
        return render(:denied) unless @state.user
        render :newrule
      end
      
      def post
        return render(:denied) unless @state.user

        code = input.code.gsub("\r", '')

        inp, out, err = Open3.popen3("/bin/diff -u #{__FILE__} -")
        inp << code
        inp.close
        diff = out.read
        name = input.name
        name = "Untitled" if name.empty?

        @rule = Rule.new
        @rule.code = diff
        @rule.date = Time.now
        @rule.name = name
        @rule.status = 'pending'
        @rule.save

        @extra = "Rule created"

        render :rule
      end
    end

    class NewVote < R '/rule/(\d+)/vote'
      def get rule_id
        return render(:denied) unless @state.user

        return render(:already_voted) if Vote.find(:first, 
                        :conditions => ['user_id = ? AND rule_id = ?', 
                        @state.user.id, rule_id])
        
        @rule = Rule.find rule_id
        vote = Vote.new
        vote.rule = @rule
        vote.user = @state.user
        vote.save
        
        if @rule.votes.size > User.find(:all).size/2
          inp, out, err = Open3.popen3("/bin/patch #{__FILE__}")
          inp << @rule.code
          inp.close
          error = err.read
          if error.empty?
            @extra = "Patch successful"
            @rule.status = "passed"
            @rule.save
          else
            @extra = "Error applying patch: #{error}"
          end
        end
        render :rule
      end
    end

    class Login < R '/login'
      def post
        return render(:failed) unless input.pass and input.user
        pass = Digest::MD5.hexdigest input.pass
        @state.user = User.find(:first, 
                                :conditions => ['name = ? AND password = ?',
                                                input.user,
                                                pass])
        return render(:failed) unless @state.user
        
        redirect R(Root)
      end
    end

    class Logout < R '/logout'
      def get
        @state.user = nil
        redirect R(Root)
      end
    end
  end

  module Views
    def layout
      html do
        head do
          title 'Ruby Nomic'
        end
        body do
          div.menu! do
            a "Home", :href => R(Root)
            br
            if @state.user
              text "Welcome "
              text @state.user.name
              text " "
              a "log out", :href => R(Logout)
            else
              form :method => "post", :action => R(Login) do
                text "Login: "
                label "User: ", :for => "user"
                input :name => "user"
                label "Pass: ", :for => "pass"
                input :type => "password", :name => "pass"
                input :type => "submit", :value => "log in"
              end
            end

            hr
          end
          div.contents! do
            yield
          end
        end
      end
    end

    def index
      div.index! do
        a "New rule", :href => R(NewRule)
        br
        h3 'Latest rules'
        @rules.each do |rule|
          hr

          h3 do
            a rule.name, :href => R(ViewRule, rule.id)
          end
          h4 rule.date
          text "Votes: "
          text rule.votes.size
          hr
        end
      end
    end

    def rule
      pre @extra if @extra
      
      h3 @rule.name
      h4 @rule.date
      pre @rule.code
      br
      text @rule.votes.size
      text " votes."
      br
      a "Vote", :href => R(NewVote, @rule.id)
    end

    def newrule
      div.new! do
        form :method => 'post', :action => R(NewRule) do
          label "Title: ", :for => 'name'
          input :name => 'name'

          br
          textarea :name => 'code', :rows => 30, :cols => 80 do
            File.read(__FILE__)
          end
          
          br
          input :type => 'submit', :value => 'create'
        end
      end
    end

    def denied
      text "Please log in to do that."
    end

    def failed
      text "Login failed."
    end

    def already_voted
      text "you have already voted on that rule."
    end
  end

  def self.create
    Nomic::Models.create_schema
    Camping::Models::Session.create_schema
  end
end
