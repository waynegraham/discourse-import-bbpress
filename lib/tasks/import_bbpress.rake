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
      sql_fetch_users
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
        puts "\nBacking up Discourse settings".yellow
        dc_backup_site_settings # back up site settings

        puts "\nSetting Discourse site settings".yellow
        dc_set_temporary_site_settings # set site settings we need

        puts "\nCreating Discourse users".yellow
        create_users

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

def sql_fetch_posts
  @bbpress_posts ||= []
  offset = 0

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
      LIMIT #{offset.to_s}, 500;
EOQ
    puts query.yellow if offset == 0
    results = @sql.query query

    count = 0

    results.each do |post|
      @bbpress_posts << post
      count += 1
    end

    puts "Batch: #{} posts".green

    offset += count
    break if count == 0 or count < 500
  end
  puts "\nNumber of posts: #{@bbpress_posts.count.to_s}".green
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

def dc_user_exists?(name)
  User.where('username = ?', name).exists?
end

def db_get_user_id(name)
  User.where('username = ?', name).first.id
end

def dc_get_user(user)
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
