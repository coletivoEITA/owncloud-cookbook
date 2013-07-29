#
# Cookbook Name:: owncloud
# Recipe:: default
#
# Copyright 2013, Onddo Labs, Sl.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#==============================================================================
# Calculate dependencies for different distros
#==============================================================================

case node['platform']
when 'debian', 'ubuntu'
  php_pkgs = %w{ php5-gd }
  php_mysql_pkg = 'php5-mysql'
  ssl_key_dir = '/etc/ssl/private'
  ssl_cert_dir = '/etc/ssl/certs'
when 'redhat', 'centos'
  if node['platform_version'].to_f < 6
    php_pkgs = %w{ php53-gd php53-mbstring php53-xml }
    php_mysql_pkg = 'php53-mysql'
  else
    php_pkgs = %w{ php-gd php-mbstring php-xml }
    php_mysql_pkg = 'php-mysql'
  end
  ssl_key_dir = '/etc/pki/tls/private'
  ssl_cert_dir = '/etc/pki/tls/certs'
when 'fedora', 'scientific', 'amazon'
  php_pkgs = %w{ php-gd php-mbstring php-xml }
  php_mysql_pkg = 'php-mysql'
  ssl_key_dir = '/etc/pki/tls/private'
  ssl_cert_dir = '/etc/pki/tls/certs'
else
  log('Unsupported platform, trying to guess packages.') { level :warn }
  php_pkgs = %w{ php-gd php-mbstring php-xml }
  php_mysql_pkg = 'php-mysql'
  ssl_key_dir = node['owncloud']['www_dir']
  ssl_cert_dir = node['owncloud']['www_dir']
end

#==============================================================================
# Initialize autogenerated passwords
#==============================================================================

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

if Chef::Config[:solo]
  if node['owncloud']['config']['dbpassword'].nil? or
    node['owncloud']['admin']['pass'].nil?
    Chef::Application.fatal!(
      'You must set owncloud\'s database and admin passwords in chef-solo mode.'
    )
  end
else
  node.set_unless['owncloud']['config']['dbpassword'] = secure_password
  node.set_unless['owncloud']['admin']['pass'] = secure_password
  node.save
end

#==============================================================================
# Install PHP
#==============================================================================

include_recipe 'php'

php_pkgs.each do |pkg|
  package pkg do
    action :install
  end
end

#==============================================================================
# Set up database
#==============================================================================

include_recipe 'database::mysql'
include_recipe 'mysql::server'

package php_mysql_pkg

mysql_connection_info = {
  :host => 'localhost',
  :username => 'root',
  :password => node['mysql']['server_root_password']
}

mysql_database node['owncloud']['config']['dbname'] do
  connection mysql_connection_info
  action :create
end

mysql_database_user node['owncloud']['config']['dbuser'] do
  connection mysql_connection_info
  database_name node['owncloud']['config']['dbname']
  host 'localhost'
  password node['owncloud']['config']['dbpassword']
  privileges [:all]
  action :grant
end

#==============================================================================
# Set up mail transfer agent
#==============================================================================

if node['owncloud']['config']['mail_smtpmode'].eql?('sendmail')
  node.default['postfix']['mail_type'] = 'client'
  node.default['postfix']['mydomain'] = node['owncloud']['server_name']
  include_recipe 'postfix::default'
end

#==============================================================================
# Download and extract ownCloud
#==============================================================================

directory node['owncloud']['www_dir']

basename = ::File.basename(node['owncloud']['download_url'])
local_file = ::File.join(Chef::Config[:file_cache_path], basename)

http_request 'HEAD owncloud' do
  message ''
  url node['owncloud']['download_url']
  action :head
  if File.exists?(local_file)
    headers "If-Modified-Since" => File.mtime(local_file).httpdate
  end
  notifies :create, "remote_file[download owncloud]", :immediately
end

remote_file "download owncloud" do
  source node['owncloud']['download_url']
  path local_file
  action :nothing
  notifies :run, "execute[extract owncloud]", :immediately
end

execute "extract owncloud" do
  command "tar xfj '#{local_file}' --no-same-owner"
  cwd node['owncloud']['www_dir']
  action :nothing
end

[
  ::File.join(node['owncloud']['dir'], 'apps'),
  ::File.join(node['owncloud']['dir'], 'config'),
  node['owncloud']['data_dir']
].each do |dir|
  directory dir do
    owner node['apache']['user']
    group node['apache']['group']
    mode 00750
    action :create
  end
end

#==============================================================================
# Set up webserver
#==============================================================================

include_recipe 'apache2::default'
include_recipe 'apache2::mod_php5'

# Disable default site
apache_site "default" do
  enable false
end

# Create virtualhost for ownCloud
web_app 'owncloud' do
  template 'vhost.erb'
  docroot node['owncloud']['dir']
  server_name node['owncloud']['server_name']
  port '80'
  enable true
end

# Enable ssl
if node['owncloud']['ssl']
  include_recipe 'apache2::mod_ssl'

  cert = OwnCloud::Certificate.new(node['owncloud']['server_name'])
  ssl_key_path = ::File.join(ssl_key_dir, 'owncloud.key')
  ssl_cert_path = ::File.join(ssl_cert_dir, 'owncloud.pem')

  # Create ssl certificate key
  file 'owncloud.key' do
    path ssl_key_path
    owner 'root'
    group 'root'
    mode 00600
    content cert.key
    action :create_if_missing
    notifies :create, "file[owncloud.pem]", :immediately
  end

  # Create ssl certificate
  file 'owncloud.pem' do
    path ssl_cert_path
    owner 'root'
    group 'root'
    mode 00644
    content cert.cert
    action :nothing
  end

  # Create SSL virtualhost
  web_app 'owncloud-ssl' do
    template 'vhost.erb'
    docroot node['owncloud']['dir']
    server_name node['owncloud']['server_name']
    port '443'
    ssl_key ssl_key_path
    ssl_cert ssl_cert_path
    enable true
  end
end

#==============================================================================
# Initialize configuration file and install ownCloud
#==============================================================================

# create autoconfig.php for the installation
template 'autoconfig.php' do
  path ::File.join(node['owncloud']['dir'], 'config', 'autoconfig.php')
  source 'autoconfig.php.erb'
  owner node['apache']['user']
  group node['apache']['group']
  mode 00640
  variables(
    :dbtype => node['owncloud']['config']['dbtype'],
    :dbname => node['owncloud']['config']['dbname'],
    :dbuser => node['owncloud']['config']['dbuser'],
    :dbpass => node['owncloud']['config']['dbpassword'],
    :dbhost => node['owncloud']['config']['dbhost'],
    :dbprefix => node['owncloud']['config']['dbtableprefix'],
    :admin_user => node['owncloud']['admin']['user'],
    :admin_pass => node['owncloud']['admin']['pass'],
    :data_dir => node['owncloud']['data_dir']
  )
  not_if { ::File.exists?(::File.join(node['owncloud']['dir'], 'config', 'config.php')) }
  notifies :restart, "service[apache2]", :immediately
  notifies :get, "http_request[run setup]", :immediately
end

# install ownCloud
http_request "run setup" do
  url "http://localhost/"
  message ''
  action :nothing
end

# Apply the configuration on attributes to config.php
ruby_block "apply config" do
  block do
    config_file = ::File.join(node['owncloud']['dir'], 'config', 'config.php')
    config = OwnCloud::Config.new(config_file)
    # exotic case: change dbtype when sqlite3 driver is available
    if node['owncloud']['config']['dbtype'] == 'sqlite' and config['dbtype'] == 'sqlite3'
      node['owncloud']['config']['dbtype'] == config['dbtype']
    end
    config.merge(node['owncloud']['config'])
    config.write
    unless Chef::Config[:solo]
      # store important options that where generated automatically by the setup
      node.set_unless['owncloud']['config']['passwordsalt'] = config['passwordsalt']
      node.set_unless['owncloud']['config']['instanceid'] = config['instanceid']
      node.save
    end
  end
end
