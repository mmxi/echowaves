require 'gravtastic'

class User < ActiveRecord::Base
  
  # prevents a user from submitting a crafted form that bypasses activation
  # anything else you want your user to change should be added here.
  attr_accessible :name, :password, :password_confirmation, :time_zone, :something, :receive_email_notifications
  attr_accessor :email_confirmation
    
  is_gravtastic :size => 60, :default => "identicon" # "monsterid" or "identicon", or "wavatar"

  acts_as_tagger
  acts_as_authentic do |c|
    c.transition_from_restful_authentication = true
  end
  
  belongs_to :personal_conversation, # personal users conversation
    :class_name => "Conversation", 
    :foreign_key => "personal_conversation_id"
  
  
  has_many :messages
  has_many :client_applications
  has_many :tokens, :class_name => "OauthToken", :order => "authorized_at desc", :include => [:client_application]
  has_many :subscriptions, :order => "activated_at DESC"
  has_many :subscribed_conversations, :through => :subscriptions, :uniq => true, :order => "name", :source => :conversation
  has_many :conversations
  has_many :conversation_visits
  has_many :recent_conversations, 
           :through => :conversation_visits, 
           :source => :conversation,
           :conditions => { :abuse_report_id => nil },
           :order => "conversation_visits.updated_at DESC",
           :limit => 10
  
  validates_presence_of     :login
  validates_length_of       :login,    :within => 3..40
  validates_uniqueness_of   :login
  validates_format_of       :login,    :with => LOGIN_REGEX, :message => "use only letters, numbers, and .-_@ please.".freeze
  validates_format_of       :name,     :with => NAME_REGEX,  :message => "avoid non-printing characters and \\&gt;&lt;&amp;/ please.".freeze, :allow_nil => true
  validates_length_of       :name,     :maximum => 100
  validates_presence_of     :email
  validates_length_of       :email,    :within => 6..100 # r@a.wk
  validates_uniqueness_of   :email
  validates_format_of       :email,    :with => EMAIL_REGEX, :message => "should look like an email address.".freeze
  validates_confirmation_of :email 
  validates_uniqueness_of   :personal_conversation_id, :if => Proc.new { |u| !u.personal_conversation_id.blank? } 
  validates_format_of       :something, :with => /^$/ # anti spam, honeypot field must be blank
  
  named_scope :active, :conditions => "activated_at is not null"
  
  # this method returns a collection of all the convos with the new messages for the user.
  def news
    subscriptions = self.subscriptions.reject { |subscription| subscription.new_messages_count == 0 }
  end

  # friends are the people you follow (you follow their personal convos)
  def friends
    self.friends_convos.map {|convo| convo.user}
  end
  
  def friends_convos
    self.subscribed_conversations.published.personal - [self.personal_conversation]
  end

  # followers are the users that follow your personal convo
  def followers
    users = Subscription.all(:conditions => ['conversation_id = ?',self.personal_conversation_id], :include => :user).map {|s| s.user}
    return users - [self]
  end
  
  def followers_convos
    followers.map { |f| f.personal_conversation }
  end
  
  def deliver_password_reset_instructions!
    reset_perishable_token!
    UserMailer.deliver_password_reset_instructions(self)
  end
  
  def deliver_private_invite_instructions!(invite)
    reset_perishable_token!
    UserMailer.deliver_private_invite_instructions(self, invite.conversation_id, invite.conversation.name, invite.token)
  end

  def deliver_public_invite_instructions!(invite)
    return unless self.receive_email_notifications
    UserMailer.deliver_public_invite_instructions(self, invite.conversation_id, invite.conversation.name)
  end

  
  def activate!
    self.activated_at = Time.now.utc
    # create initial personal conversation
    conversation = Conversation.add_personal(self)
    self.personal_conversation_id = conversation.id
    self.save
  end

  def active?
    self.activated_at != nil
  end
  
  def login=(value)
    write_attribute :login, (value ? value.downcase : nil)
  end

  def email=(value)
    write_attribute :email, (value ? value.downcase : nil)
  end

  def mark_last_viewed_as_read
    self.subscriptions(:order => 'activated_at DESC').first.mark_read unless self.subscriptions.empty?
  end

  def update_last_viewed_subscription(conversation)
    if sub = self.subscriptions.find_by_conversation_id(conversation.id)
      sub.activate!
    end
  end

  def conversation_visit_update(conversation)
    conversation.add_visit(self)
    self.mark_last_viewed_as_read
    self.update_last_viewed_subscription(conversation)
  end

  def follow(convo, token=nil)
    invite = Invite.find(:first, :conditions => ["user_id = ? and conversation_id = ?", self, convo.id ])
    if !convo.private? || self == convo.owner
      subscription = convo.add_subscription(self)
      subscription.mark_read
    elsif convo.private? && !invite.blank? && ( token == invite.token )
      subscription = convo.add_subscription(self)
      subscription.mark_read
      invite.reset_token!
    else
      return false
    end
    return true
  end
  
  def unfollow(convo)
    convo.remove_subscription(self)
    # remove invitation if exists so the user can be invited again
    invite = Invite.find(:first, :conditions => ["user_id = ? and conversation_id = ?", self, convo.id ])
    invite.destroy unless invite.blank?
  end
  
  def all_convos_tags
    tags = [] # have to initialize the array
    self.subscriptions.each do |subscription|
      subscription.conversation.taggings.each do |tagging|
        tags |= [tagging.tag] # removing duplicate tags
      end
    end
    tags
  end
  
  def all_convos_tag_counts
    tag_counts = [] # have to initialize the array
    self.subscriptions.each do |subscription|      
      tag_counts |= subscription.conversation.tag_counts
    end
    tag_counts
  end
  
  def convos_by_tag(tag)
    convos = []
    self.subscriptions.each do |subscription|
      subscription.conversation.taggings.each do |tagging|
        convos |= [subscription.conversation] if(tagging.tag.to_s == tag)
      end
    end
    convos
  end

  def date
    self.created_at.strftime '%b %d, %Y'
  end
  
  def name_and_nick
    (self.name.blank? or self.name == self.login) ? self.login : "#{self.name} (#{self.login})"
  end
  
  def bookmark_tag
    "star_#{self.id}"
  end
  
  alias_method :unsafe_to_xml, :to_xml
  
  def to_xml(options = {})
    excluded_by_default = [:crypted_password, :salt, :remember_token, :something,
                          :remember_token_expires_at, :activated_at, :perishable_token, :persistence_token,
                          :single_access_token, :email, :receive_email_notifications]
    options[:except] = (options[:except] ? options[:except] + excluded_by_default : excluded_by_default)   
    unsafe_to_xml(options)
  end
  
  def to_param
    "#{id}-#{login.parameterize}"
  end
  
end
