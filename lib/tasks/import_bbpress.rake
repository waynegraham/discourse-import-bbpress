############################################################
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

    if TEST_MODE then puts "\n*** Running in TEST mode. No changes to the Discourse database will be made".yellow end


  end
end

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
