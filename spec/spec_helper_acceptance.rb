require 'beaker-puppet'
require 'beaker-rspec/spec_helper'
require 'beaker-rspec/helpers/serverspec'
require 'beaker/ca_cert_helper'
require 'erb'

def stop_firewall_on(host)
  case host['platform']
  when %r{debian}
    on host, 'iptables -F'
  when %r{fedora|el-7}
    on host, puppet('resource', 'service', 'firewalld', 'ensure=stopped')
  when %r{el-|centos}
    on host, puppet('resource', 'service', 'iptables', 'ensure=stopped')
  when %r{ubuntu}
    on host, puppet('resource', 'service', 'ufw', 'ensure=stopped')
  else
    logger.notify("Not sure how to clear firewall on #{host['platform']}")
  end
end

# Project root
PROJ_ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..'))
TEST_FILES = File.expand_path(File.join(File.dirname(__FILE__), 'acceptance', 'files'))

# Helper for setting the activemq host in erb templates.
def activemq_host
  'activemq'
end

def install_modules_on(host)
  install_ca_certs_on(host)
  puppet_module_install_on(host, source: PROJ_ROOT, module_name: 'puppet_agent')
  on host, puppet('module', 'install', 'puppetlabs-stdlib'), { acceptable_exit_codes: [0] }
  on host, puppet('module', 'install', 'puppetlabs-inifile'), { acceptable_exit_codes: [0] }
  on host, puppet('module', 'install', 'puppetlabs-apt'), { acceptable_exit_codes: [0] }
end

unless ENV['BEAKER_provision'] == 'no'
  # Install puppet-server on master
  options['is_puppetserver'] = true
  master['puppetservice'] = 'puppetserver'
  master['puppetserver-confdir'] = '/etc/puppetlabs/puppetserver/conf.d'
  master['type'] = 'aio'
  install_puppet_agent_on master, { version: ENV['PUPPET_CLIENT_VERSION'] || '5.5.16', puppet_collection: 'puppet5' }

  install_modules_on master

  # Install activemq on master
  install_puppetlabs_release_repo(master, 'puppetlabs')
  install_package master, 'activemq'

  ['truststore', 'keystore'].each do |ext|
    scp_to master, "#{TEST_FILES}/activemq.#{ext}", "/etc/activemq/activemq.#{ext}"
  end

  erb = ERB.new(File.read("#{TEST_FILES}/activemq.xml.erb"))
  create_remote_file master, '/etc/activemq/activemq.xml', erb.result(binding)

  stop_firewall_on master
  on master, puppet('resource', 'service', 'activemq', 'ensure=running')

  # sleep to give activemq time to start
  sleep 10
end

def agent_opts(master_fqdn)
  {
    main: { color: 'ansi' },
    agent: { ssldir: '$vardir/ssl', server: master_fqdn },
  }
end

def mcollective_paths(host)
  if %r{windows}i.match?(host['platform'])
    { etc: 'C:/ProgramData/PuppetLabs/mcollective/etc',
     libexec: 'C:/ProgramData/PuppetLabs/mcollective/libexec',
     client_plugins: 'C:/ProgramData/PuppetLabs/mcollective/plugins',
     server_plugins: 'C:/ProgramData/PuppetLabs/mcollective/plugins',
     logs: 'C:/ProgramData/PuppetLabs/mcollective/var/log' }
  else
    { etc: '/etc/mcollective',
     libexec: '/usr/libexec/mcollective',
     client_plugins: '/usr/share/mcollective/plugins',
     server_plugins: '/opt/puppetlabs/mcollective/plugins',
     logs: '/var/log' }
  end
end

def mcollective_new_paths(host)
  if %r{windows}i.match?(host['platform'])
    { etc: 'C:/ProgramData/PuppetLabs/mcollective/etc',
     libexec: 'C:/ProgramData/PuppetLabs/mcollective/libexec',
     client_plugins: 'C:/ProgramData/PuppetLabs/mcollective/plugins',
     server_plugins: 'C:/ProgramData/PuppetLabs/mcollective/plugins',
     logs: 'C:/ProgramData/PuppetLabs/mcollective/var/log',
     facts: 'C:/ProgramData/Puppetlabs/mcollective/etc/facts.yaml' }
  else
    { etc: '/etc/puppetlabs/mcollective',
     libexec: '/usr/libexec/mcollective',
     client_plugins: '/usr/share/mcollective/plugins',
     server_plugins: '/opt/puppetlabs/mcollective/plugins',
     logs: '/var/log/puppetlabs',
     facts: '/etc/mcollective/facts.yaml:/etc/puppetlabs/mcollective/facts.yaml' }
  end
end

def puppet_conf(host)
  if %r{windows}i.match?(host['platform'])
    'C:/ProgramData/PuppetLabs/puppet/etc/puppet.conf'
  else
    '/etc/puppetlabs/puppet/puppet.conf'
  end
end

def package_name(host)
  if %r{windows}i.match?(host['platform'])
    'Puppet Agent*'
  else
    'puppet-agent'
  end
end

def setup_puppet_on(host, opts = {})
  opts = { agent: false, mcollective: false }.merge(opts)
  host['type'] = 'aio'

  puts "Setup aio puppet on #{host}"
  configure_type_defaults_on host
  install_puppet_agent_on host, { version: ENV['PUPPET_CLIENT_VERSION'] || '5.5.16', puppet_collection: 'puppet5' }

  puppet_opts = agent_opts(master.to_s)
  if %r{windows}i.match?(host['platform'])
    # MODULES-4242: ssldir setting is cleared but files not copied on Windows upgrading from Puppet 3
    puppet_opts[:agent].delete(:ssldir)
  end
  configure_puppet_on(host, puppet_opts)

  if opts[:mcollective]
    stop_firewall_on host

    mco_paths = mcollective_new_paths(host)
    on host, "mkdir -p #{mco_paths[:etc]}"

    ['ca_crt.pem', 'server.crt', 'server.key', 'client.crt', 'client.key'].each do |file|
      scp_to host, "#{TEST_FILES}/#{file}", "#{mco_paths[:etc]}/#{file}"
    end

    ['client.cfg', 'server.cfg'].each do |file|
      erb = ERB.new(File.read("#{TEST_FILES}/#{file}.erb"))
      create_remote_file host, "#{mco_paths[:etc]}/#{file}", erb.result(binding)
    end

    on host, "mkdir #{mco_paths[:etc]}/ssl-clients"
    scp_to host, "#{TEST_FILES}/client.crt", "#{mco_paths[:etc]}/ssl-clients/client.pem"
    on host, "mkdir -p #{mco_paths[:libexec]}/plugins"

    # Ensure the domain used to find activemq_host resolves to an ip address.
    # The domain is set based on the certificate used for testing.
    on host, puppet('resource', 'host', activemq_host, "ip=#{master['ip'] || master.ip}")
    on host, puppet('resource', 'service', 'mcollective', 'ensure=stopped')
    on host, puppet('resource', 'service', 'mcollective', 'ensure=running')
    on host, puppet('resource', 'service', 'mcollective', 'enable=true')
  end

  if opts[:agent]
    puts 'Clean SSL on all hosts and disable firewalls'
    hosts.each do |h|
      stop_firewall_on h
    end
  else
    install_modules_on host
  end
end

def configure_agent_on(host, agent_run = false)
  configure_type_defaults_on host
  install_modules_on host unless agent_run
end

def wait_for_finish_on(host)
  return unless %r{windows}i.match?(host['platform'])

  tries = 1
  # cygpath doesn't expose temp directory as there is no CSIDL for it.  Assume it's always `Temp` in the Local Application Data directory
  # CSIDL reference - https://msdn.microsoft.com/en-us/library/windows/desktop/bb774096%28v=vs.85%29.aspx?f=255&MSPPError=-2147217396
  until on(host, 'cat `cygpath -smF 28`/Temp/puppet_agent_upgrade.pid', acceptable_exit_codes: [0, 1]).exit_code == 1 || tries > 45
    puts 'waiting for upgrade to complete ...'
    sleep 2
    tries += 1
  end
end

def teardown_puppet_on(host)
  puts "Purge puppet from #{host}"
  ensure_type = 'purged'
  # Note pc_repo is specific to the module's manifests. This is knowledge we need to clean
  # the machine after each run.
  case host['platform']
  when %r{debian|ubuntu}
    on host, '/opt/puppetlabs/bin/puppet module install puppetlabs-apt --version 7.7.1', { acceptable_exit_codes: [0, 1] }
    clean_repo = "include apt\napt::source { 'pc_repo': ensure => absent, notify => Package['puppet-agent'] }"
  when %r{fedora|el|centos}
    clean_repo = "yumrepo { 'pc_repo': ensure => absent, notify => Package['puppet-agent'] }"
  when %r{osx}
    ensure_type = 'absent'
  when %r{sles}
    ensure_type = 'absent'
    clean_repo = "file { '/etc/zypp/repos.d/pc_repo.repo': ensure => absent, notify => Package['puppet-agent'] }"
  else
    logger.notify("Not sure how to remove repos on #{host['platform']}")
    clean_repo = ''
  end

  if %r{windows}.match?(host['platform'])
    install_dir = on(host, 'facter.bat env_windows_installdir').output.tr('\\', '/').chomp
    scp_to host, "#{TEST_FILES}/uninstall.ps1", 'uninstall.ps1'
    on host, 'rm -rf C:/ProgramData/PuppetLabs'
    on host, 'powershell.exe -File uninstall.ps1 < /dev/null'
    on host, "rm -rf '#{install_dir}'"
  else
    pp = <<-EOS
#{clean_repo}
package { ['puppet-agent', 'puppet', 'mcollective', 'mcollective-client']: ensure => #{ensure_type} }
EOS
    on host, puppet('apply', '-e', "\"#{pp}\"", '--no-report')
  end
end

RSpec.configure do |c|
  # Readable test descriptions
  c.formatter = :documentation
end
