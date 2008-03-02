#!/usr/bin/ruby
#TODO: 
# User views and controls, eg. changing password, top scores, descriptions
#
# Controller and view for showing more than just the 10 most recent pending
# patches.
#
# Controller and views for passed and rejected patches.
#
# Enable creation of a new patch based on an existing one, to fix bugs spotted
# in it, etc.  Probably with a default title based on the existing one.
#
# Set up sandboxing for the main app and provide the ability to run pending
# patches in a sandbox to check them for bugs in the same environment as the
# server.
#
# Refactor some stuff from Controllers into Models
#
# Comment everything, probably as a patch per class.
#
# Implement some kind of comment system on rules. (hoodwinkd?)
#
# rss feeds for various patch types
#
# xmlrpc interfaces for creating/downloading patches, maybe other stuff
#
# get some more people talking about the thing and a couple more people using
# it
#
# Add a page about what the thing is, who to talk to about an account and how
# to contribute
#
# Option to anyone to "prune" patches that have been idle over N days, to get
# them out of the pending patches list.  Possibly allow them to still pass.
#
# Search function for patches.
#
# Possibly formalise this list as a wishlist page.
#
# Perform a git commit with the patch's title whenever a patch is passed.

require 'camping/session'
require 'open3'
require 'coderay'

Camping.goes :Nomic

module Nomic
  include Camping::Session

  module Models
    class Rule < Base
      has_many :votes
      belongs_to :user
    end

    class Vote < Base
      belongs_to :rule
      belongs_to :user
    end

    class User < Base
      has_many :votes
      has_many :rules
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
    class AddYea < V 2
      def self.up
        add_column :nomic_votes, :yea, :boolean, 
                   :null => false, :default => true
      end
    end

    class AddRuleAuthor < V 3
      def self.up
        add_column :nomic_rules, :user_id, :integer, :null => false, 
                   :default => 1
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

    class ViewRuleCode < R '/rule/(\d+)/code'
      def get id
        @rule = Rule.find id
        render :rule
        inp, out, err = Open3.popen3("patch -o /tmp/r#{id} #{__FILE__} -")
        inp << @rule.code
        inp.close

        @extra = err.read
        return render(:error) unless @extra.empty?

        @code = File.read("/tmp/r#{id}")
        @code = CodeRay.scan(@code, :ruby).html(:line_numbers => :table,
                                                :css => :style)
        render :rule_code

      end
    end

    class RuleDownload < R '/rule/(\d+)/nomic.rb'
      def get id
        @rule = Rule.find id
        inp, out, err = Open3.popen3("patch -o /tmp/r#{id} #{__FILE__} -")
        inp << @rule.code
        inp.close

        @extra = err.read
        return render(:error) unless @extra.empty?

        @headers['Content-Type'] = '/text/plain'
        return File.read("/tmp/r#{id}")
      end
    end

    class DownloadLatest < R '/nomic.rb'
      def get
        @headers['Content-Type'] = '/text/plain'
        return File.read(__FILE__)
      end
    end

    class ViewLatest < R '/code'
      def get
        @code = File.read(__FILE__)
        @code = CodeRay.scan(@code, :ruby).html(:line_numbers => :table,
                                                :css => :style)
        render :latest_code
      end
    end

    class NewRule < R '/rule/new'
      def get
        return render(:denied) unless @state.user
        render :newrule
      end
      
      def post
        return render(:denied) unless @state.user

        code = input.codefile.tempfile.read if input.codefile and
                        input.codefile.is_a? Hash

        code ||= input.code.gsub("\r", '')

        inp, out, err = Open3.popen3("diff -u #{__FILE__} -")
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
        @rule.user = @state.user
        @rule.save

        @extra = "Rule created"

        render :rule
      end
    end

    class NewVote < R '/rule/(\d+)/vote/(\w+)'
      def get rule_id, yea_str
        return render(:denied) unless @state.user

        old_vote = Vote.find(:first, 
                             :conditions => ['user_id = ? AND rule_id = ?', 
                                             @state.user.id, rule_id])
        
        @rule = Rule.find rule_id

        yea = false
        if yea_str == "yea"
          yea = true
        end
        
        if @rule.status != "pending"
          @extra = "You cannot vote on a rule that is not pending."
          return render(:rule)
        end

        if old_vote
          if old_vote.yea == yea
            @extra = "You had voted this way already."
            return render(:rule)
          end

          old_vote.yea = yea
          old_vote.save
          @extra = "Vote changed. " + pass_or_fail(rule)
          return render(:rule)
        end

        yea = false
        if yea_str == "yea"
          yea = true
        end
        
        vote = Vote.new
        vote.rule = @rule
        vote.user = @state.user
        vote.yea  = yea
        vote.save
       
       	@extra = pass_or_fail(rule)
        render :rule
      end

      def pass_or_fail rule
        yeas = @rule.votes.select{|v| v.yea}
        nays = @rule.votes.select{|v| not v.yea}
        user_count = User.find(:all).size

        if nays.size - yeas.size > user_count/2
          @rule.status = "failed"
          @rule.save
          extra = "Rule has been declined."
        elsif yeas.size - nays.size > user_count/2
          inp, out, err = Open3.popen3("patch #{__FILE__}")
          inp << @rule.code
          inp.close
          error = err.read
          if error.empty?
            extra = "Patch successful"
            @rule.status = "passed"
            @rule.save
          else
            extra = "Error applying patch: #{error}"
          end
        end
	return extra
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

    class Style < R '/style'
      def get
        style = <<STYLE
body {
  font: 13.34px helvetica, arial, clean, sans-serif;
  background: #cccc99;
}
#wrap {
  background: #ffffff;
  margin: 0 auto;
  padding: 10px;
  width: 700px;
  border-radius: 3px;
  -moz-border-radius: 3px;
}
STYLE
        return style
      end
    end
  end

  module Views
    Mab.set :indent, 2

    def layout
      html do
        head do
          title 'Ruby Nomic'
          link :type => 'text/css', :rel => 'stylesheet', :href => R(Style)
        end
        body do
          div.wrap! do
            div.menu! do
              a "Home", :href => R(Root)
              text " | "
              a "New rule", :href => R(NewRule)
              text " | "
              a "View", :href => R(ViewLatest)
              text " | "
              a "Download", :href => R(DownloadLatest)
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
    end

    def index
      div.index! do
        h3 'Pending rules'
        @rules.each do |rule|
          hr

          h3 do
            a rule.name, :href => R(ViewRule, rule.id)
            text " by #{rule.user.name}"
          end
          h4 rule.date
          text "Yea: "
          text rule.votes.select{|v| v.yea}.size
          text " | Nay: "
          text rule.votes.select{|v| not v.yea}.size
          hr
        end
      end
    end

    def rule
      pre @extra if @extra
      
      h3 "#{@rule.name} by #{@rule.user.name}"
      h4 @rule.date
      
      a "view code", :href => R(ViewRuleCode, @rule.id)
      text " | "
      a "download", :href => R(RuleDownload, @rule.id)
      br
      
      h4 "Votes:"
      a "Yea: ", :href => R(NewVote, @rule.id, "yea")
      text @rule.votes.select{|v| v.yea}.size
      text " | "
      a "Nay: ", :href => R(NewVote, @rule.id, "nay") 
      text @rule.votes.select{|v| not v.yea}.size
      
      h4 "Patch:"
      text CodeRay.scan(@rule.code, :ruby).html(:line_numbers => :table,
                                                :css => :style)
    end

    def rule_code
      @code
    end
    
    def latest_code
      @code
    end

    def newrule
      div.new! do
        form :method => 'post', :action => R(NewRule), 
             :enctype => 'multipart/form-data' do
          label "Title: ", :for => 'name'
          input :name => 'name'

          br
          label "Upload: ", :for => 'codefile'
          input :type => 'file', :name => 'codefile'
          br
          label "Or edit: ", :for => 'code'
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

    def error
      text "Unexpected error:"
      text @extra if @extra
    end
  end

  def self.create
    Nomic::Models.create_schema
    Camping::Models::Session.create_schema
  end
end            