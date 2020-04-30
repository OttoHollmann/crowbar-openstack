monasca_server = node_search_with_cache("roles:monasca-server").first
monasca_api_url = MonascaHelper.api_network_url(monasca_server)

include_recipe "apache2"

is_controller = node["roles"].include?("ceilometer-server")

memcached_instance("ceilometer-server") if is_controller

keystone_settings = KeystoneHelper.keystone_settings(node, @cookbook_name)
monasca_project = monasca_server[:monasca][:service_tenant]

db_settings = fetch_database_settings

include_recipe "database::client"
include_recipe "#{db_settings[:backend_name]}::client"
include_recipe "#{db_settings[:backend_name]}::python-client"

db_auth = node[:ceilometer][:db].dup
unless node.roles.include? "ceilometer-server"
  # pickup password to database from ceilometer-server node
  node_controllers = node_search_with_cache("roles:ceilometer-server")
  if node_controllers.empty?
    db_auth[:password] = node_controllers[0][:ceilometer][:db][:password]
  end
end

db_connection = fetch_database_connection_string(db_auth)

is_compute_agent = node.roles.include?("ceilometer-agent") && node.roles.any? { |role| /^nova-compute-/ =~ role }
is_swift_proxy = node.roles.include?("ceilometer-swift-proxy-middleware") && node.roles.include?("swift-proxy")

# Find hypervisor inspector
hypervisor_inspector = nil
libvirt_type = nil
instance_discovery_method = "libvirt_metadata"
if is_compute_agent
  if ["xen"].include?(node[:nova][:libvirt_type])
    instance_discovery_method = "workload_partitioning"
    hypervisor_inspector = "libvirt"
    libvirt_type = node[:nova][:libvirt_type]
  end
  if ["vmware"].include?(node[:nova][:libvirt_type])
    instance_discovery_method = "workload_partitioning"
    hypervisor_inspector = "vsphere"
  else
    hypervisor_inspector = "libvirt"
    libvirt_type = node[:nova][:libvirt_type]
  end
end

metering_time_to_live = node[:ceilometer][:database][:metering_time_to_live]
event_time_to_live = node[:ceilometer][:database][:event_time_to_live]

# We store the value of time to live in days, but config file expects
# seconds
if metering_time_to_live > 0
  metering_time_to_live = metering_time_to_live * 3600 * 24
end
if event_time_to_live > 0
  event_time_to_live = event_time_to_live * 3600 * 24
end

template node[:ceilometer][:config_file] do
    source "ceilometer.conf.erb"
    owner "root"
    group node[:ceilometer][:group]
    mode "0640"
    variables(
      debug: node[:ceilometer][:debug],
      rabbit_settings: fetch_rabbitmq_settings,
      keystone_settings: keystone_settings,
      monasca_project: monasca_project,
      memcached_servers: MemcachedHelper.get_memcached_servers(node,
        CrowbarPacemakerHelper.cluster_nodes(node, "ceilometer-server")),
      metering_secret: node[:ceilometer][:metering_secret],
      database_connection: db_connection,
      node_hostname: node["hostname"],
      hypervisor_inspector: hypervisor_inspector,
      libvirt_type: libvirt_type,
      metering_time_to_live: metering_time_to_live,
      event_time_to_live: event_time_to_live,
      instance_discovery_method: instance_discovery_method,
      is_compute_agent: is_compute_agent
    )
    if is_compute_agent
      notifies :restart, "service[nova-compute]"
    end
    if is_swift_proxy
      notifies :restart, "service[swift-proxy]"
    end
    notifies :reload, resources(service: "apache2")
end

template "/etc/ceilometer/pipeline.yaml" do
  source "pipeline.yaml.erb"
  owner "root"
  group "root"
  mode "0644"
  variables({
              compute_interval: node[:ceilometer][:compute_interval],
              image_interval: node[:ceilometer][:image_interval],
              volume_interval: node[:ceilometer][:volume_interval],
              network_interval: node[:ceilometer][:network_interval],
              swift_interval: node[:ceilometer][:swift_interval],
              monasca_api_url: monasca_api_url
            })
  if is_compute_agent
    notifies :restart, "service[nova-compute]"
  end
  if is_swift_proxy
    notifies :restart, "service[swift-proxy]"
  end
end

template "/etc/ceilometer/polling_pipeline.yaml" do
  source "polling_pipeline.yaml.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(
    swift_interval: node[:ceilometer][:swift_interval],
    monasca_api_url: monasca_api_url
  )
  notifies :restart, "service[swift-proxy]" if is_swift_proxy
end

template "/etc/ceilometer/event_pipeline.yaml" do
  source "event_pipeline.yaml.erb"
  owner "root"
  group "root"
  mode "0644"
  notifies :restart, "service[nova-compute]" if is_compute_agent
  notifies :restart, "service[swift-proxy]" if is_swift_proxy
end
