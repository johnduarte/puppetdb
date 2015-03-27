step "Run an agent to create the SSL certs" do
  if options[:type] == 'aio' then
    hosts.each do |host|
      on(host, puppet("agent -t"), :acceptable_exit_codes => [0,1])
    end
    on master, puppet("cert --sign --all"), :acceptable_exit_codes => [0,24]
  else
  with_puppet_running_on(
    master,
    :master => {:autosign => 'true', :trace => 'true'}) do
    run_agent_on(database, "--test")
  end
  end
end
