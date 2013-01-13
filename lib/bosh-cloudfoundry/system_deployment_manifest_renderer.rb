# Copyright (c) 2012-2013 Stark & Wayne, LLC

module Bosh; module CloudFoundry; end; end

# Renders a +SystemConfig+ model into a System's BOSH deployment
# manifest(s).
class Bosh::CloudFoundry::SystemDeploymentManifestRenderer
  include FileUtils
  attr_reader :system_config, :common_config, :bosh_config

  def initialize(system_config, common_config, bosh_config)
    @system_config = system_config
    @common_config = common_config
    @bosh_config = bosh_config
  end

  # Render deployment manifest(s) for a system
  # based on the model data in +system_config+
  # (a +SystemConfig+ object).
  def perform
    validate_system_config

    deployment_name = "#{system_config.system_name}-core"

    manifest = base_manifest(
      deployment_name,
      bosh_config.target_uuid,
      system_config.bosh_provider,
      system_config.system_name,
      system_config.release_name,
      system_config.release_version,
      system_config.stemcell_name,
      system_config.stemcell_version,
      cloud_properties_for_server_flavor(system_config.core_server_flavor),
      system_config.core_ip,
      system_config.root_dns,
      system_config.admin_emails,
      system_config.common_password,
      system_config.common_persistent_disk,
      system_config.aws_security_group
    )

    dea_config.add_core_jobs_to_manifest(manifest)
    dea_config.add_resource_pools_to_manifest(manifest)
    dea_config.add_jobs_to_manifest(manifest)
    dea_config.merge_manifest_properties(manifest)

    chdir system_config.system_dir do
      mkdir_p("deployments")
      File.open("deployments/#{system_config.system_name}-core.yml", "w") do |file|
        file << manifest.to_yaml
      end
      # `open "deployments/#{system_config.system_name}-core.yml"`
    end
  end

  def validate_system_config
    s = system_config
    must_not_be_nil = [
      :system_dir,
      :bosh_provider,
      :release_name,
      :release_version,
      :stemcell_name,
      :stemcell_version,
      :core_server_flavor,
      :core_ip,
      :root_dns,
      :admin_emails,
      :common_password,
      :common_persistent_disk,
      :aws_security_group,
    ]
    must_not_be_nil_failures = must_not_be_nil.inject([]) do |list, attribute|
      list << attribute unless system_config.send(attribute)
      list
    end
    if must_not_be_nil_failures.size > 0
      raise "These SystemConfig fields must not be nil: #{must_not_be_nil_failures.inspect}"
    end
  end

  def dea_config
    @dea_config ||= Bosh::CloudFoundry::Config::DeaConfig.build_from_system_config(system_config)
  end

  # Converts a server flavor (such as 'm1.large' on AWS) into
  # a BOSH deployment manifest +cloud_properties+ YAML string
  # For AWS & m1.large, it would be:
  #   'instance_type: m1.large'
  def cloud_properties_for_server_flavor(server_flavor)
    if aws?
      { "instance_type" => server_flavor }
    else
      raise 'Please implement #{self.class}#cloud_properties_for_server_flavor'
    end
  end

  def aws?
    system_config.bosh_provider == "aws"
  end

  # 
  def base_manifest(
      deployment_name,
      director_uuid,
      bosh_provider,
      system_name,
      release_name,
      release_version,
      stemcell_name,
      stemcell_version,
      core_cloud_properties,
      core_ip,
      root_dns,
      admin_emails,
      common_password,
      common_persistent_disk,
      aws_security_group
    )
    # This large, terse, pretty-printed manifest can be
    # generated by loading in a spec/assets/deployments/*.yml file
    # and pretty-printing it.
    #
    #   manifest = YAML.load_file('spec/assets/deployments/aws-core-only.yml')
    #   require "pp"
    #   pp manifest
    {"name"=>deployment_name,
     "director_uuid"=>director_uuid,
     "release"=>{"name"=>release_name, "version"=>release_version},
     "compilation"=>
      {"workers"=>10,
       "network"=>"default",
       "reuse_compilation_vms"=>true,
       "cloud_properties"=>{"instance_type"=>"m1.medium"}},
     "update"=>
      {"canaries"=>1,
       "canary_watch_time"=>"30000-150000",
       "update_watch_time"=>"30000-150000",
       "max_in_flight"=>4,
       "max_errors"=>1},
     "networks"=>
      [{"name"=>"default",
        "type"=>"dynamic",
        "cloud_properties"=>{"security_groups"=>[aws_security_group]}},
       {"name"=>"vip_network",
        "type"=>"vip",
        "cloud_properties"=>{"security_groups"=>[aws_security_group]}}],
     "resource_pools"=>
      [{"name"=>"core",
        "network"=>"default",
        "size"=>1,
        "stemcell"=>{"name"=>stemcell_name, "version"=>stemcell_version},
        "cloud_properties"=>core_cloud_properties,
        "persistent_disk"=>common_persistent_disk}],
     "jobs"=>
      [{"name"=>"core",
        "template"=>
         ["postgres",
          "nats",
          "router",
          "health_manager",
          "cloud_controller",
          "acm",
          "serialization_data_server",
          "stager",
          "uaa",
          "vcap_redis"],
        "instances"=>1,
        "resource_pool"=>"core",
        "networks"=>
         [{"name"=>"default", "default"=>["dns", "gateway"]},
          {"name"=>"vip_network", "static_ips"=>[core_ip]}],
        "persistent_disk"=>common_persistent_disk}],
     "properties"=>
      {"domain"=>"mycompany.com",
       "env"=>nil,
       "networks"=>{"apps"=>"default", "management"=>"default"},
       "router"=>
        {"client_inactivity_timeout"=>600,
         "app_inactivity_timeout"=>600,
         "local_route"=>core_ip,
         "status"=>
          {"port"=>8080, "user"=>"router", "password"=>"c1oudc0wc1oudc0w"}},
       "nats"=>
        {"user"=>"nats",
         "password"=>"c1oudc0wc1oudc0w",
         "address"=>core_ip,
         "port"=>4222},
       "db"=>"ccdb",
       "ccdb"=>
        {"template"=>"postgres",
         "address"=>core_ip,
         "port"=>2544,
         "databases"=>
          [{"tag"=>"cc", "name"=>"appcloud"},
           {"tag"=>"acm", "name"=>"acm"},
           {"tag"=>"uaa", "name"=>"uaa"}],
         "roles"=>
          [{"name"=>"root", "password"=>"c1oudc0wc1oudc0w", "tag"=>"admin"},
           {"name"=>"acm", "password"=>"c1oudc0wc1oudc0w", "tag"=>"acm"},
           {"name"=>"uaa", "password"=>"c1oudc0wc1oudc0w", "tag"=>"uaa"}]},
       "cc"=>
        {"description"=>"Cloud Foundry",
         "srv_api_uri"=>"http://api.mycompany.com",
         "password"=>"c1oudc0wc1oudc0w",
         "token"=>"TOKEN",
         "allow_debug"=>true,
         "allow_registration"=>true,
         "admins"=>admin_emails,
         "admin_account_capacity"=>
          {"memory"=>2048, "app_uris"=>32, "services"=>16, "apps"=>16},
         "default_account_capacity"=>
          {"memory"=>2048, "app_uris"=>32, "services"=>16, "apps"=>16},
         "new_stager_percent"=>100,
         "staging_upload_user"=>"vcap",
         "staging_upload_password"=>"c1oudc0wc1oudc0w",
         "uaa"=>
          {"enabled"=>true,
           "resource_id"=>"cloud_controller",
           "token_creation_email_filter"=>[""]},
         "service_extension"=>{"service_lifecycle"=>{"max_upload_size"=>5}},
         "use_nginx"=>false},
       "mysql_gateway"=>
        {"ip_route"=>core_ip,
         "token"=>"TOKEN",
         "supported_versions"=>["5.1"],
         "version_aliases"=>{"current"=>"5.1"}},
       "mysql_node"=>
        {"ip_route"=>core_ip,
         "available_storage"=>2048,
         "password"=>"c1oudc0wc1oudc0w",
         "max_db_size"=>256,
         "supported_versions"=>["5.1"],
         "default_version"=>"5.1"},
       "redis_gateway"=>
        {"ip_route"=>core_ip,
         "token"=>"TOKEN",
         "supported_versions"=>["2.2"],
         "version_aliases"=>{"current"=>"2.2"}},
       "redis_node"=>
        {"ip_route"=>core_ip,
         "available_memory"=>256,
         "supported_versions"=>["2.2"],
         "default_version"=>"2.2"},
       "mongodb_gateway"=>
        {"ip_route"=>core_ip,
         "token"=>"TOKEN",
         "supported_versions"=>["1.8", "2.0"],
         "version_aliases"=>{"current"=>"2.0", "deprecated"=>"1.8"}},
       "mongodb_node"=>
        {"ip_route"=>core_ip,
         "available_memory"=>256,
         "supported_versions"=>["1.8", "2.0"],
         "default_version"=>"1.8"},
       "postgresql_gateway"=>
        {"ip_route"=>core_ip,
         "admin_user"=>"psql_admin",
         "admin_passwd_hash"=>nil,
         "token"=>"TOKEN",
         "supported_versions"=>["9.0"],
         "version_aliases"=>{"current"=>"9.0"}},
       "postgresql_node"=>
        {"ip_route"=>core_ip,
         "admin_user"=>"psql_admin",
         "admin_passwd_hash"=>nil,
         "available_storage"=>2048,
         "max_db_size"=>256,
         "max_long_tx"=>30,
         "supported_versions"=>["9.0"],
         "default_version"=>"9.0"},
       "postgresql_server"=>{"max_connections"=>30, "listen_address"=>"0.0.0.0"},
       "acm"=>{"user"=>"acm", "password"=>"c1oudc0wc1oudc0w"},
       "acmdb"=>
        {"address"=>core_ip,
         "port"=>2544,
         "roles"=>
          [{"tag"=>"admin", "name"=>"acm", "password"=>"c1oudc0wc1oudc0w"}],
         "databases"=>[{"tag"=>"acm", "name"=>"acm"}]},
       "serialization_data_server"=>
        {"upload_token"=>"TOKEN",
         "use_nginx"=>false,
         "upload_timeout"=>10,
         "port"=>8090,
         "upload_file_expire_time"=>600,
         "purge_expired_interval"=>30},
       "service_lifecycle"=>
        {"download_url"=>core_ip,
         "mount_point"=>"/var/vcap/service_lifecycle",
         "tmp_dir"=>"/var/vcap/service_lifecycle/tmp_dir",
         "resque"=>
          {"host"=>core_ip, "port"=>3456, "password"=>"c1oudc0wc1oudc0w"},
         "nfs_server"=>{"address"=>core_ip, "export_dir"=>"/cfsnapshot"},
         "serialization_data_server"=>[core_ip]},
       "stager"=>
        {"max_staging_duration"=>120,
         "max_active_tasks"=>20,
         "queues"=>["staging"]},
       "uaa"=>
        {"cc"=>{"token_secret"=>"TOKEN_SECRET", "client_secret"=>"CLIENT_SECRET"},
         "admin"=>{"client_secret"=>"CLIENT_SECRET"},
         "login"=>{"client_secret"=>"CLIENT_SECRET"},
         "batch"=>{"username"=>"uaa", "password"=>"c1oudc0wc1oudc0w"},
         "port"=>8100,
         "catalina_opts"=>"-Xmx128m -Xms30m -XX:MaxPermSize=128m"},
       "uaadb"=>
        {"address"=>core_ip,
         "port"=>2544,
         "roles"=>
          [{"tag"=>"admin", "name"=>"uaa", "password"=>"c1oudc0wc1oudc0w"}],
         "databases"=>[{"tag"=>"uaa", "name"=>"uaa"}]},
       "vcap_redis"=>
        {"address"=>core_ip,
         "port"=>3456,
         "password"=>"c1oudc0wc1oudc0w",
         "maxmemory"=>500000000},
       "service_plans"=>
        {"mysql"=>
          {"free"=>
            {"job_management"=>{"high_water"=>1400, "low_water"=>100},
             "configuration"=>
              {"allow_over_provisioning"=>true,
               "capacity"=>200,
               "max_db_size"=>128,
               "max_long_query"=>3,
               "max_long_tx"=>30,
               "max_clients"=>20,
               "backup"=>{"enable"=>true}}}},
         "postgresql"=>
          {"free"=>
            {"job_management"=>{"high_water"=>1400, "low_water"=>100},
             "configuration"=>
              {"capacity"=>200,
               "max_db_size"=>128,
               "max_long_query"=>3,
               "max_long_tx"=>30,
               "max_clients"=>20,
               "backup"=>{"enable"=>true}}}},
         "mongodb"=>
          {"free"=>
            {"job_management"=>{"high_water"=>3000, "low_water"=>100},
             "configuration"=>
              {"allow_over_provisioning"=>true,
               "capacity"=>200,
               "quota_files"=>4,
               "max_clients"=>500,
               "backup"=>{"enable"=>true}}}},
         "rabbit"=>
          {"free"=>
            {"job_management"=>{"low_water"=>100, "high_water"=>1400},
             "configuration"=>
              {"max_memory_factor"=>0.5, "max_clients"=>512, "capacity"=>200}}},
         "redis"=>
          {"free"=>
            {"job_management"=>{"high_water"=>1400, "low_water"=>100},
             "configuration"=>
              {"capacity"=>200,
               "max_memory"=>16,
               "max_swap"=>32,
               "max_clients"=>500,
               "backup"=>{"enable"=>true}}}},
         "vblob"=>
          {"free"=>
            {"job_management"=>{"low_water"=>100, "high_water"=>1400},
             "configuration"=>{"capacity"=>200}}}},
       "dea"=>{"max_memory"=>512}}}
  end

end
