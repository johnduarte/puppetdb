test_name "setup aio, puppetserver for pdb"

hosts.each do |host|
  unless host['platform'] == 'el-7-x86_64'
    fail "only works on redhat-7"
  end
end

step "update system"
hosts.each do |host|
  on host, "yum clean all && yum makecache && yum update -y"
end

step "install utils"
hosts.each do |host|
  on host, "yum install -y git wget vim"
end

step "add puppet-agent nightly repo"
hosts.each do |host|
  on host, "wget http://nightlies.puppetlabs.com/puppet-agent-latest/repo_configs/rpm/pl-puppet-agent-latest-el-7-x86_64.repo && cp pl-puppet-agent-latest-el-7-x86_64.repo /etc/yum.repos.d/"
end


step "add puppetserver nightly repo on master"
on master, "wget http://nightlies.puppetlabs.com/puppetserver-latest/repo_configs/rpm/pl-puppetserver-latest-el-7-x86_64.repo && cp pl-puppetserver-latest-el-7-x86_64.repo /etc/yum.repos.d/"

step "install and start puppetserver on master"
on master, "yum install -y puppetserver"
on master, "service puppetserver start"

step "Install puppet-agent on the db node"
on database, "yum install -y puppet-agent"


step "Add puppetlabs binaries to the front of your paths on each box"
hosts.each do |host|
  on host, "echo PATH=\"/opt/puppetlabs/bin:/opt/puppetlabs/puppet/bin:$PATH\" >> ~/.bashrc"
end

step "Add IPs and roles to /etc/hosts"
hosts.each do |host|
  on host, "echo '#{master.ip} puppet' >> /etc/hosts"
  on host, "echo '#{database.ip} puppetdb' >> /etc/hosts"
end

step "Setup the SSL and sanity check the puppet installation"
hosts.each do |host|
  on(host, puppet("agent -t"), :acceptable_exit_codes => [0,1])
end

step "On the master sign the cert for the db node"
  on master, puppet("cert --sign --all")

step "Rerun the agent on the db node"
on database, puppet("agent -t")

step "Install puppetdb from source see https://docs.puppetlabs.com/puppetdb/latest/install_from_source.html"

step "Step 1, Install Prerequisites"
  step "Facter installed as part of AIO above"
  step "Install Java 1.7"
    on database, "yum install -y java-1.7.0-openjdk unzip"
  step "Leiningen will be installed in step 2 below"
  step "Git installed above"

step "Step 2, Option A: Install Leiningen"
  on database, "curl --tlsv1 -Lk https://raw.github.com/technomancy/leiningen/stable/bin/lein -o /usr/local/bin/lein"
  on database, "chmod +x /usr/local/bin/lein"


step "Step 2, Option A: Install PuppetDB from source"
step "Clone puppetdb to each box"
hosts.each do |host|
  on host, "git clone git://github.com/puppetlabs/puppetdb.git"
  on host, "cd puppetdb && git checkout stable"
  # Docs needs to note that stable is needed for AIO
end

# Required for AIO
#step "Add puppetlabs binaries to the front of your paths on each box"
#hosts.each do |host|
#  on host, "echo PATH=\"/opt/puppetlabs/bin:/opt/puppetlabs/puppet/bin:$PATH\" >> ~/.bashrc"
#end

step "On DB node install puppetdb (step 1: bootstrap)"
# rake has to be vendored rake /opt/puppetlabs/puppet/bin/rake
# Facter has to be on path???
if options['type'] == 'aio' then
  rake="/opt/puppetlabs/puppet/bin/rake"
else
  rake="rake"
end
on database, "cd puppetdb && #{rake} package:bootstrap"

step "On DB node install puppetdb (step 2: install)"
on database, "cd puppetdb && LEIN_ROOT=true #{rake} install"

step "create a puppetdb user and group MISSING FROM DOC"
on database, "groupadd puppetdb"
on database, "useradd puppetdb -g puppetdb"

step "Step 3, Option A: Run the SSL Configuration Script"
on database, "/usr/sbin/puppetdb ssl-setup"

step "Step 4: Configure HTTPS"
on database, "echo 'host = #{database}'  >>  /etc/puppetdb/conf.d/jetty.ini"

step "Step 5: Configure Database"
step "Bump PuppetDB's memory usage to account for the embedded DB"
on database, "sed -i 's/Xmx192m/Xmx1g/' /etc/sysconfig/puppetdb"

step "Setup PuppetDB ownership correctly MISSING FROM DOC"
# More restrictive method may be better. Check failed read/write.
on database, "chown -R puppetdb:puppetdb /etc/puppetdb"
on database, "chown -R puppetdb:puppetdb /var/lib/puppetdb"

step "Step 6: Start the PuppetDB Service (Why does docs use init.d syntax?)"
start_puppetdb(database)

step "Enable puppetdb"
on database, puppet("resource service puppetdb ensure=running enable=true")

step "Connect PuppetDB to master https://docs.puppetlabs.com/puppetdb/latest/connect_puppet_master.html"

step "Step 1: Install Plugins: On Platforms Without Packages"
step "Source code cloned above"

step "Copy puppetdb bits into ruby path on master CORRECTION FOR DOCS"
          # cp -R ext/master/lib/puppet /usr/lib/ruby/site_ruby/1.8/puppet
on master, "cd puppetdb && cp -R puppet/lib/puppet/* /opt/puppetlabs/puppet/lib/ruby/vendor_ruby/puppet/"

step "Step 2: Edit Config Files"
pupconfpath = master.puppet['confdir']

step "Edit puppetdb.conf file, needs to be owned by 'puppet' user (e.g puppet or pe-puppet)"

on master, "echo '[main]' >> #{pupconfpath}/puppetdb.conf"
on master, "echo '  server = #{database}' >> #{pupconfpath}/puppetdb.conf"
on master, "echo '  port = 8081' >> #{pupconfpath}/puppetdb.conf"

step "Add puppetdb storage to puppet.conf"
on master, "echo '  storeconfigs = true' >> #{pupconfpath}/puppet.conf"
on master, "echo '  storeconfigs_backend = puppetdb' >> #{pupconfpath}/puppet.conf"
on master, "echo '  reports = store,puppetdb' >> #{pupconfpath}/puppet.conf"

step "Create routes.yaml"
route_file = master.puppet('master')['route_file']
content = <<-EOS
---
  master:
    facts:
      terminus: puppetdb
      cache: yaml
EOS
create_remote_file(master, route_file, content)

step "Ensure correct ownership, see note for puppetdb.conf"
on master, "chown -R puppet:puppet #{pupconfpath}"

step "Step 4: Restart server on master"
#TODO: write a start_puppetserver helper
on master, "service puppetserver restart"
sleep 30

step "Run puppet agent on hosts"
hosts.each do |host|
  on host, puppet("agent -t")
end
