##########################################################
# IMPORT bbPress to Discourse
#
# version 0.0.1
############################################################

require 'mysql2'

namespace :import do
  desc "Import posts and comments from a bbPress instance"
  task "bbpress" => "environment" do
    @config = YAML.load_file('config/import_bbpress.yml')
    TEST_MODE = @config['test_mode']
    DC_ADMIN = @config['discourse_admin']
    MARKDOWN_LINEBREAKS = true

    RateLimiter::disable

    if TEST_MODE then puts "\n*** Running in TEST mode. No changes to the Discourse database will be made.***".yellow end

    # Exit task if discourse admin user doesn't exist
    #
    if Discourse.system_user.nil?
      unless dc_user_exists(DC_ADMIN) then
        puts "\nERROR: The discourse admin #{DC_ADMIN} does not exist".red
        puts "|nBailing...".red

        exit_script
      else
        DC_ADMIN = dc_get_user(DC_ADMIN)
      end
    else
      DC_ADMIN = Discourse.system_user
    end

    begin
      # prompt for markdown settings 
      input = ''
      puts "Do you want to enable traditional markdown-linebreaks? (linebreaks are ignored unless the line ends with two spaces)"
      print "y/N? > "
      input = STDIN.gets.chomp
      MARKDOWN_LINEBREAKS = ( /y(es)?/i.match(input) or input.empty? )
      puts "\nUsing markdown linebreaks: " + MARKDOWN_LINEBREAKS.to_s.green

      sql_connect

      puts "\n*** Fetching users from MySQL to migrate to Discourse".yellow
      sql_fetch_users

      puts "\n*** Grabbing posts for import Discourse".yellow
      sql_fetch_posts


      if TEST_MODE then

        begin
          require 'irb'
          ARGV.clear
          IRB.start
        rescue :IRB_EXIT
        end

        exit_script
      else
        puts "\n*** Backing up Discourse settings".yellow
        dc_backup_site_settings # back up site settings

        puts "\n*** Setting Discourse site settings".yellow
        dc_set_temporary_site_settings # set site settings we need

        puts "\n*** Creating Discourse users".yellow
        create_users

        puts "\n*** Importing posts and topics to Discourse".yellow
        sql_import_posts

        puts "\n*** Restoring settings".yellow
        dc_restore_site_settings
      end

    ensure
      @sql.close if @sql
    end

    puts "\n*** DONE ***".green

  end

end

############################################################
# Methods
############################################################

### SQL convenience
def sql_connect
  begin
    @sql = Mysql2::Client.new(
      :host => @config['sql_server'],
      :username => @config['sql_user'],
      :password => @config['sql_password'],
      :database => @config['sql_database']
    )
  rescue Mysql2::Error => e
    puts "\nERROR: Connection to Database failed\n#{e.message}".red
    exit_script
  end

  puts "\nConnected to SQL DB".green
end

def sql_fetch_posts(*parse)
  @bbpress_posts ||= []
  @post_count ||= @offset = 0

  puts "\nCollecting Posts...".blue

  loop do
    query =<<EOQ
      SELECT t.topic_id, t.topic_title,
      u.user_login, u.id,
      f.forum_name,
      p.post_time, p.post_text
      FROM bb_posts p
      JOIN bb_topics t on t.topic_id = p.topic_id
      JOIN bb_users u ON u.id = p.poster_id
      JOIN bb_forums f on t.forum_id = f.forum_id
      ORDER BY t.topic_id ASC, t.topic_title ASC, p.post_id ASC
      LIMIT #{@offset.to_s}, 500;
EOQ
    puts query.yellow if @offset == 0
    results = @sql.query query

    count = 0

    results.each do |post|
      @bbpress_posts << post
      count += 1
    end

    puts "Batch: (#{@offset % 500}) posts".green
    @offset += count


    if !TEST_MODE then
      #sql_import_posts
      #@bbpress_posts.clear # for managing memory
    end

    break if count == 0 or count < 500
  end
  puts "\nNumber of posts: #{@bbpress_posts.count.to_s}".green
end

def sql_import_posts
  topics = {}
  @bbpress_posts.each do |bbpress_post|
    @post_count += 1

    # details on writer of the post
    user = @bbpress_users.find {|k| k['user_login'] == bbpress_post['user_login']}

    if user.nil?
      puts "Warning: User (#{bbpress_post['id']}) #{bbpress_post['user_login']} not found in user list!".red
    end

    # get the discourse user of this post
    dc_user = dc_get_user(bbpress_username_to_dc(user['user_login']))

    category = create_category(
      bbpress_post['forum_name'].downcase,
      DC_ADMIN
    )

    topic_title = sanitize_topic bbpress_post['topic_title']

    is_new_topic = false

    topic = topics[bbpress_post['topic_id']]
    if topic.nil?
      is_new_topic = true
    end

    progress = @post_count.percent_of(@bbpress_posts.count).round.to_s

    text = sanitize_text bbpress_post['post_text']

    # create!
    post_creator = nil

    if is_new_topic
      print "\n[#{progress}%] Creating topic ".yellow + topic_title +
        " (#{Time.at(bbpress_post['post_time'])}) in category ".yellow +
          "#{category.name}"
          post_creator = PostCreator.new(
            dc_user,
            skip_validations: true,
            raw: text,
            title: topic_title,
            archetype: 'regular',
            category: category.name,
            created_at: Time.at(bbpress_post['post_time']),
            updated_at: Time.at(bbpress_post['post_time'])
          )

          ## for a new topic: also clear mail deliveries
          ActionMailer::Base.deliveries = []
    else
      print ".".yellow
      $stdout.flush
      post_creator = PostCreator.new(
        dc_user,
        raw: text,
        skip_validations: true,
        topic_id: topic,
        created_at: Time.at(bbpress_post['post_time']),
        updated_at: Time.at(bbpress_post['post_time'])
      )
    end

    post = nil

    begin
      post = post_creator.create
    rescue Exception => e
      puts "Error #{e} on post #{bbpress_post['post_id']}:\n#{text}"
      puts "--"
      puts e.inspect
      puts e.backtrace
      abort
    end

    # Everything set, save the topic
    if post_creator.errors.present? # Skip if not valid for some reason
      puts "\nContents of topic from post #{bbpress_post['post_id']} failed to ".red+
        "import: #{post_creator.errors.full_messages}".red
    else
      post_serializer = PostSerializer.new(post, scope: true, root: false)
      post_serializer.topic_slug = post.topic.slug if post.topic.present?
      post_serializer.draft_sequence = DraftSequence.current(dc_user, post.topic.draft_key)
      # save id to hash
      topics[bbpress_post['topic_id']] = post.topic.id if is_new_topic
      puts "\nThe topic thread for '#{topic_title}' was created".green if is_new_topic
    end
  end
end

# Returns a Discourse category where imported posts will go
def create_category(name, owner)
  if Category.where('name = ?', name).empty? then
    puts "\nCreating category '#{name}'".yellow
    Category.create!(name: name, user_id: owner.id)
  else
    Category.where('name = ?', name).first
  end
end

def create_users
  @bbpress_users.each do |bbpress_user|
    dc_username = bbpress_username_to_dc(bbpress_user['user_nicename'])
    if(dc_username.length < 3)
      dc_username = dc_username.ljust(3, '0')
    end
    dc_email = bbpress_user['user_email']
    # create email address
    if dc_email.nil? or dc_email.empty? then
      dc_email = dc_username + "@has.no.email"
    end

    #approved = bbpress_user['user_status'] == 1
    approved_by_id = DC_ADMIN.id

    # TODO: check how 'admins' are noted
    admin = false

    # Create user if it doesn't exist
    if User.where('username = ?', dc_username).empty? then
      begin
        dc_user = User.create!(
          username: dc_username,
          name: bbpress_user['display_name'],
          email: dc_email,
          active: true,
          approved: true,
          admin: admin
        )
      rescue Exception => e
        puts "Error #{e} on user #{dc_username} <#{dc_email}>"
        puts "---"
        puts e.inspect
        puts e.backtrace
        abort
      end
      puts "User (#{bbpress_user['id']}) #{bbpress_user['user_login']} (#{dc_username} / #{dc_email}) created".green
    else
      puts "User (#{bbpress_user['id']}) #{bbpress_user['user_login']} (#{dc_username} / #{dc_email}) found".yellow
    end
  end
end

def sql_fetch_users
  @bbpress_users ||= []
  offset = 0

  puts "\nCollecting Users...".blue

  loop do
    count = 0
    query = <<EOQ
      SELECT id, user_login, user_pass, user_nicename, user_email, user_url, user_registered, user_status, display_name
      FROM bb_users
      LIMIT #{offset}, 50;
EOQ

    puts query.yellow if offset == 0
    users = @sql.query query
    users.each do |user|
      @bbpress_users << user
      count += 1
    end

    offset += count
    break if count == 0
  end

  puts "Number of users: #{@bbpress_users.count.to_s}".green

end

def sanitize_topic(text)
  CGI.unescapeHTML(text)
end

def sanitize_text(text)
  text = CGI.unescapeHTML(text)

  # screaming
  unless seems_quiet?(text)
    text = '<capslock> ' + text.downcase
  end

  unless seems_pronounceable?(text)
    text = "<symbols>\n" + text
  end

  # remove tag IDs
  text.gsub! /\[(\/?[a-zA-Z]+(=("[^"]*?"|[^\]]*?))?):[a-z0-9]+\]/, '[\1]'

  # completely remove youtube, soundcloud and url tags as those links are oneboxed
  text.gsub! /\[(youtube|soundcloud|url|img)\](.*?)\[\/\1\]/m, "\n"+'\2'+"\n"

  # yt tags are custom for our forum
  text.gsub! /\[yt\]([a-zA-Z0-9_-]{11})\[\/yt\]/, ' http://youtu.be/\1 '

  # convert newlines to markdown syntax
  text.gsub! /([^\n])\n/, '\1  '+"\n" if MARKDOWN_LINEBREAKS

  # strange links (maybe soundcloud)
  # <!-- m --><a class="postlink" href="http://link">http://link</a><!-- m -->
  text.gsub! /<!-- m --><a class="postlink" href="(.*?)">.*?<\/a><!-- m -->/m, ' \1 '

  # convert code blocks to markdown syntax
  text.gsub! /\[code\](.*?)\[\/code\]/m do |match|
    "\n    " + $1.gsub(/(  )?\n(.)/, "\n"+'    \2') + "\n"
  end

  # size tags
  # discourse likes numbers from 4-40 (pt), phpbb uses 20 to 200 (percent)
  # [size=85:az5et819]dump dump[/size:az5et819]
  text.gsub! /\[size=(\d+)(%?)\]/ do |match|
    pt = $1.to_i / 100 * 14 # 14 is the default text size
    pt = 40 if pt > 40
    pt = 4 if pt < 4

    "[size=#{pt}]"
  end

  # edit invalid quotes
  text.gsub! /\[quote\]/, '[quote=""]'

  text
end

### Methods adapted from lib/text_sentinel.rb
def seems_quiet?(text)
  # We don't allow all upper case content in english
  not((text =~ /[A-Z]+/) && !(text =~ /[^[:ascii:]]/) && (text == text.upcase))
end

def seems_pronounceable?(text)
  # At least some non-symbol characters
  # (We don't have a comprehensive list of symbols, but this will eliminate some noise)
  text.gsub(symbols_regex, '').size > 0
end

def symbols_regex
  /[\ -\/\[-\`\:-\@\{-\~]/m
end

# Checks if Discourse admin user exists
def discourse_admin_exists?
end

# Set temporary site settings needed for this rake task
def dc_set_temporary_site_settings
  # don't backup this first one
  SiteSetting.send("traditional_markdown_linebreaks=", MARKDOWN_LINEBREAKS)

  SiteSetting.send("unique_posts_mins=", 0)
  SiteSetting.send("rate_limit_create_topic=", 0)
  SiteSetting.send("rate_limit_create_post=", 0)
  SiteSetting.send("max_topics_per_day=", 10000)
  SiteSetting.send("title_min_entropy=", 0)
  SiteSetting.send("body_min_entropy=", 0)
  SiteSetting.send("min_post_length=", 1) # never set this to 0
  SiteSetting.send("newuser_spam_host_threshold=", 1000)
  SiteSetting.send("min_topic_title_length=", 2)
  SiteSetting.send("max_topic_title_length=", 512)
  SiteSetting.send("newuser_max_links=", 1000)
  SiteSetting.send("newuser_max_images=", 1000)
  SiteSetting.send("max_word_length=", 5000)
  SiteSetting.send("email_time_window_mins=", 1)
end

def dc_backup_site_settings
  s = {}

  s['unique_posts_mins']            = SiteSetting.unique_posts_mins
  s['rate_limit_create_topic']      = SiteSetting.rate_limit_create_topic
  s['rate_limit_create_post']       = SiteSetting.rate_limit_create_post
  s['max_topics_per_day']           = SiteSetting.max_topics_per_day
  s['title_min_entropy']            = SiteSetting.title_min_entropy
  s['body_min_entropy']             = SiteSetting.body_min_entropy
  s['min_post_length']              = SiteSetting.min_post_length
  s['newuser_spam_host_threshold']  = SiteSetting.newuser_spam_host_threshold
  s['min_topic_title_length']       = SiteSetting.min_topic_title_length
  s['newuser_max_links']            = SiteSetting.newuser_max_links
  s['newuser_max_images']           = SiteSetting.newuser_max_images
  s['max_word_length']              = SiteSetting.max_word_length
  s['email_time_window_mins']       = SiteSetting.email_time_window_mins
  s['max_topic_title_length']       = SiteSetting.max_topic_title_length

  @site_settings = s
end

def dc_restore_site_settings
  s = @site_settings
  SiteSetting.send("unique_posts_mins=", s['unique_posts_mins'])
  SiteSetting.send("rate_limit_create_topic=", s['rate_limit_create_topic'])
  SiteSetting.send("rate_limit_create_post=", s['rate_limit_create_post'])
  SiteSetting.send("max_topics_per_day=", s['max_topics_per_day'])
  SiteSetting.send("title_min_entropy=", s['title_min_entropy'])
  SiteSetting.send("body_min_entropy=", s['body_min_entropy'])
  SiteSetting.send("min_post_length=", s['min_post_length'])
  SiteSetting.send("newuser_spam_host_threshold=", s['newuser_spam_host_threshold'])
  SiteSetting.send("min_topic_title_length=", s['min_topic_title_length'])
  SiteSetting.send("newuser_max_links=", s['newuser_max_links'])
  SiteSetting.send("newuser_max_images=", s['newuser_max_images'])
  SiteSetting.send("max_word_length=", s['max_word_length'])
  SiteSetting.send("email_time_window_mins=", s['email_time_window_mins'])
  SiteSetting.send("max_topic_title_length=", s['max_topic_title_length'])
end

def dc_user_exists?(name)
  User.where('username = ?', name).exists?
end

def db_get_user_id(name)
  User.where('username = ?', name).first.id
end

def dc_get_user(name)
  User.where('username = ?', name).first
end

def current_unix_time
  Time.now.to_i
end

def unix_to_human_time(unix_time)
  Time.at(unix_time).strftime("%d/%m/%Y %H:%M")
end

def bbpress_username_to_dc(name)
  # create username from full name; only letters and numbers
  username = name.tr('^A-Za-z0-9', '').downcase
  # Maximum length of a Discourse username is 15 characters
  username = username[0,15]
end

def exit_script
  puts "\nRake task exiting\n".yellow
  abort
end

############################################################
# Classes
############################################################

# Add colorization to String for STOUT/STERR
class String
  def red
    colorize(self, 31)
  end

  def green
    colorize(self, 32)
  end

  def yellow
    colorize(self, 33)
  end

  def blue
    colorize(self, 34)
  end

  def colorize(text, color_code)
    "\033[#{color_code}m#{text}\033[0m"
  end
end

# Convenience class for calculating percentages
class Numeric
  def percent_of(n)
    self.to_f / n.to_f * 100
  end
end
