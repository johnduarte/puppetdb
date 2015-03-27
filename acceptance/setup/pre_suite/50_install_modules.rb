require 'beaker/dsl/install_utils'

extend Beaker::DSL::InstallUtils

step "Install the puppetdb module and dependencies" do
  on master, "puppet module install puppetlabs/puppetdb"
  if options[:type] == 'aio'
    # patch puppetdb module for version 4.1.0
    on master, "sed -i \"s=/etc/puppet'=/etc/puppetlabs/puppet'=\" /etc/puppetlabs/code/environments/production/modules/puppetdb/manifests/params.pp"
  end
end
