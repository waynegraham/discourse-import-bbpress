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
      puts "Using markdown linebreaks: " + MARKDOWN_LINEBREAKS.to_s.green

      sql_connect

    end

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


# Checks if Discourse admin user exists
def discourse_admin_exists?
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
