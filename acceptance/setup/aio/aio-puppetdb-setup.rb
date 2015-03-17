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

step "Clone puppetdb to each box"
hosts.each do |host|
  on host, "git clone git://github.com/puppetlabs/puppetdb.git"
  on host, "cd puppetdb && git checkout stable && git remote add rbrw git://github.com/rbrw/puppetdb.git && git fetch rbrw && git merge rbrw/ticket/stable/pdb-1227-prefer-aio-path-in-ssl-setup"
end

step "On DB node install puppetdb deps"
on database, "yum install -y java-1.7.0-openjdk unzip"

on database, "curl --tlsv1 -Lk https://raw.github.com/technomancy/leiningen/stable/bin/lein -o /usr/local/bin/lein"
on database, "chmod +x /usr/local/bin/lein"

step "On DB node install puppetdb (step 1: bootstrap)"
on database, "cd puppetdb && rake package:bootstrap"

step "On DB node install puppetdb (step 2: install)"
on database, "cd puppetdb && LEIN_ROOT=true rake install"

step "create a puppetdb user and group"
on database, "groupadd puppetdb"
on database, "useradd puppetdb -g puppetdb"

step "setup PuppetDB ssl dir"
on database, "/usr/sbin/puppetdb ssl-setup"

step "update the jetty.ini for pdb"
on database, "echo 'host = #{database}'  >>  /etc/puppetdb/conf.d/jetty.ini"

step "Bump PuppetDB's memory usage to account for the embedded DB"
on database, "sed -i 's/Xmx192m/Xmx1g/' /etc/sysconfig/puppetdb"

step "Setup PuppetDB ownership correctly"
on database, "chown -R puppetdb:puppetdb /etc/puppetdb"
on database, "chown -R puppetdb:puppetdb /var/lib/puppetdb"
on database, "service puppetdb start"

sleep 20

step "Copy puppetdb bits into ruby path on master"
on master, "cp -R puppetdb/puppet/lib/puppet/* /opt/puppetlabs/puppet/lib/ruby/vendor_ruby/puppet/"

step "Add puppetdb storage to puppet.conf"
pupconfpath = master.puppet['confdir']
on master, "echo '  storeconfigs = true' >> #{pupconfpath}/puppet.conf"
on master, "echo '  storeconfigs_backend = puppetdb' >> #{pupconfpath}/puppet.conf"
on master, "echo '  reports = store,puppetdb' >> #{pupconfpath}/puppet.conf"

step "Create puppetdb.conf file"
on master, "echo '[main]' >> #{pupconfpath}/puppetdb.conf"
on master, "echo '  server = #{database}' >> #{pupconfpath}/puppetdb.conf"
on master, "echo '  port = 8081' >> #{pupconfpath}/puppetdb.conf"

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

step "Ensure correct ownership"
on master, "chown -R puppet:puppet #{pupconfpath}"

step "Restart server on master"
on master, "service puppetserver restart"

sleep 10

step "Run puppet agent on hosts"
hosts.each do |host|
  on host, puppet("agent -t")
end
