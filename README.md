# What is this

This set of rake tasks imports users, threads, and posts from a bbPress
instance into Discourse.

* Post dates and authors are preserved
* User accounts are created from bbPress, but have no login
  capabilities. The emails addresses are set, and gravatars work, but
users will need to log in to activate their accounts.
* There is a `test` mode to test the connection to the mysql server and
  read posts


**Use at your onw risk!** Seriously, test this on a dummy Discourse
installation first.


# Instructions

* **Important:** *disable* your email configuration or ou will spam all
  your users with hundreds of emails. To do this, add this to your
environemnt config (e.g. `config/environments/development.rb`):

```ruby
config.action_mailer.delivery_method = :test
config.action_mailer.smtp_settings = { address: "localhost", port: 1025 }
```

Install and start `mailcatcher` to see when all mails have been sent:

```shell
$ gem install mailcatcher
$ mailcatcher --http-ip 0.0.0.0
```

* Be sure to have at least one user in your Discourse instance. If not,
  create one and set the username in `config/import_bbpress.yml`.

* Edit `config/import_bbpress.yml` with your database connection
  information and `discourse_admin` username.

* Install the `mysql2` gem:

```
$ bundle
```

**Note:** You may need to install the header files for mysql. For OS X,
you can do this with `brew install mysql`; for Debian, `sudo apt-get
install libmysqlclient-dev`; on CentOS/RHEL, `sudo yum install
mysql-devel`.


* Copy `config/import_bbpress.yml` to your `discourse/config` directory
* Copy `lib/tasks/import_bbpress.rake` to your `discourse/lib/tasks/`
  directory
* In your discourse instance, run `rake import:bbpress`

**Note:** if you are running multisite, you will need pass your database
instance: `export RAILS_DB=<your_database> rake import:bbpress`

* Cross your fingers
* If everything worked, deploy
* Be sure to have your users reset their passwords on the new Discourse
  site.

# Contributing

Please make all pull requests to the develop branch. And example process
for making a pull request:

1. Fork and clone the repo
1. `$ git checkout -b feature-my-awesome-improvement`
1. Make changes and commit
1. Push changes to Github
1. Create a **pull request** from `feature-my-awesome-improvement` on
   your repo to `develop` on the main repo
1. Celebrate your contribution to Open Source!!
