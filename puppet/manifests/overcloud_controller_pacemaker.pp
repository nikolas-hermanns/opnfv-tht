# Copyright 2015 Red Hat, Inc.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

Pcmk_resource <| |> {
  tries     => 10,
  try_sleep => 3,
}

# TODO(jistr): use pcs resource provider instead of just no-ops
Service <|
  tag == 'aodh-service' or
  tag == 'cinder-service' or
  tag == 'ceilometer-service' or
  tag == 'congress-service' or
  tag == 'glance-service' or
  tag == 'heat-service' or
  tag == 'keystone-service' or
  tag == 'neutron-service' or
  tag == 'nova-service' or
  tag == 'sahara-service' or
  tag == 'tacker-service'
|> {
  hasrestart => true,
  restart    => '/bin/true',
  start      => '/bin/true',
  stop       => '/bin/true',
}

include ::tripleo::packages
include ::tripleo::firewall

if $::hostname == downcase(hiera('bootstrap_nodeid')) {
  $pacemaker_master = true
  $sync_db = true
} else {
  $pacemaker_master = false
  $sync_db = false
}

$enable_fencing = str2bool(hiera('enable_fencing', false)) and hiera('step') >= 5
$enable_load_balancer = hiera('enable_load_balancer', true)

# When to start and enable services which haven't been Pacemakerized
# FIXME: remove when we start all OpenStack services using Pacemaker
# (occurrences of this variable will be gradually replaced with false)
$non_pcmk_start = hiera('step') >= 4

if hiera('step') >= 1 {

  create_resources(kmod::load, hiera('kernel_modules'), {})
  create_resources(sysctl::value, hiera('sysctl_settings'), {})
  Exec <| tag == 'kmod::load' |>  -> Sysctl <| |>

  include ::timezone

  if count(hiera('ntp::servers')) > 0 {
    include ::ntp
  }

  # Ceph
  $enable_ceph = hiera('ceph_storage_count', 0) > 0 or hiera('enable_ceph_storage', false) or hiera('compute_enable_ceph_storage', false)

  if $enable_ceph {
    $mon_initial_members = downcase(hiera('ceph_mon_initial_members'))
    if str2bool(hiera('ceph_ipv6', false)) {
      $mon_host = hiera('ceph_mon_host_v6')
    } else {
      $mon_host = hiera('ceph_mon_host')
    }
    class { '::ceph::profile::params':
      mon_initial_members => $mon_initial_members,
      mon_host            => $mon_host,
    }
    include ::ceph::conf
    include ::ceph::profile::mon
    Class['ceph::profile::mon'] ~> Exec['enable_ceph_on_boot']
  }

  if str2bool(hiera('enable_ceph_storage', false)) {
    if str2bool(hiera('ceph_osd_selinux_permissive', true)) {
      exec { 'set selinux to permissive on boot':
        command => "sed -ie 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config",
        onlyif  => "test -f /etc/selinux/config && ! grep '^SELINUX=permissive' /etc/selinux/config",
        path    => ['/usr/bin', '/usr/sbin'],
      }

      exec { 'set selinux to permissive':
        command => 'setenforce 0',
        onlyif  => "which setenforce && getenforce | grep -i 'enforcing'",
        path    => ['/usr/bin', '/usr/sbin'],
      } -> Class['ceph::profile::osd']
    }

    include ::ceph::conf
    include ::ceph::profile::osd
    Class['ceph::profile::osd'] ~> Exec['enable_ceph_on_boot']
  }

  exec { 'enable_ceph_on_boot':
    command     => 'chkconfig ceph on',
    refreshonly => true,
    path        => '/usr/sbin:/usr/bin:/sbin:/bin',
  }


  $controller_node_ips = split(hiera('controller_node_ips'), ',')
  $controller_node_names = split(downcase(hiera('controller_node_names')), ',')
  $ctlplane_interface = hiera('nic1')

  if $enable_load_balancer {
    class { '::tripleo::loadbalancer' :
      controller_hosts          => $controller_node_ips,
      controller_hosts_names    => $controller_node_names,
      control_virtual_interface => $ctlplane_interface,
      manage_vip                => false,
      mysql_clustercheck        => true,
      haproxy_service_manage    => false,
    }
  }

  Class['::ceph::conf'] ->
  Class['::ceph::profile::mon'] -> Class['::ceph::profile::osd'] -> Class['::tripleo::loadbalancer']
  Class['::ceph::profile::osd'] -> Class['::mysql::server']
  Class['::ceph::profile::osd'] -> Class['::mongodb::server']


  $pacemaker_cluster_members = downcase(regsubst(hiera('controller_node_names'), ',', ' ', 'G'))
  $corosync_ipv6 = str2bool(hiera('corosync_ipv6', false))
  if $corosync_ipv6 {
    $cluster_setup_extras = { '--ipv6' => '' }
  } else {
    $cluster_setup_extras = {}
  }
  class { '::pacemaker':
    hacluster_pwd => hiera('hacluster_pwd'),
  } ->
  class { '::pacemaker::corosync':
    cluster_members      => $pacemaker_cluster_members,
    setup_cluster        => $pacemaker_master,
    cluster_setup_extras => $cluster_setup_extras,
  }
  class { '::pacemaker::stonith':
    disable => !$enable_fencing,
  }
  if $enable_fencing {
    include ::tripleo::fencing

    # enable stonith after all fencing devices have been created
    Class['tripleo::fencing'] -> Class['pacemaker::stonith']
  }

  # FIXME(gfidente): sets 200secs as default start timeout op
  # param; until we can use pcmk global defaults we'll still
  # need to add it to every resource which redefines op params
  Pacemaker::Resource::Service {
    op_params => 'start timeout=200s stop timeout=200s',
  }

  # Only configure RabbitMQ in this step, don't start it yet to
  # avoid races where non-master nodes attempt to start without
  # config (eg. binding on 0.0.0.0)
  # The module ignores erlang_cookie if cluster_config is false
  $rabbit_ipv6 = str2bool(hiera('rabbit_ipv6', false))
  if $rabbit_ipv6 {
      $rabbit_env = merge(hiera('rabbitmq_environment'), {
        'RABBITMQ_SERVER_START_ARGS' => '"-proto_dist inet6_tcp"'
      })
  } else {
    $rabbit_env = hiera('rabbitmq_environment')
  }

  class { '::rabbitmq':
    service_manage          => false,
    tcp_keepalive           => false,
    config_kernel_variables => hiera('rabbitmq_kernel_variables'),
    config_variables        => hiera('rabbitmq_config_variables'),
    environment_variables   => $rabbit_env,
  } ->
  file { '/var/lib/rabbitmq/.erlang.cookie':
    ensure  => file,
    owner   => 'rabbitmq',
    group   => 'rabbitmq',
    mode    => '0400',
    content => hiera('rabbitmq::erlang_cookie'),
    replace => true,
  }

  # NOTE(gfidente): the following vars are needed on all nodes so they
  # need to stay out of pacemaker_master conditional.
  # The addresses mangling will hopefully go away when we'll be able to
  # configure the connection string via hostnames, until then, we need to pass
  # the list of IPv6 addresses *with* port and without the brackets as 'members'
  # argument for the 'mongodb_replset' resource.
  if str2bool(hiera('mongodb::server::ipv6', false)) {
    $mongo_node_ips_with_port_prefixed = prefix(hiera('mongo_node_ips'), '[')
    $mongo_node_ips_with_port = suffix($mongo_node_ips_with_port_prefixed, ']:27017')
    $mongo_node_ips_with_port_nobr = suffix(hiera('mongo_node_ips'), ':27017')
  } else {
    $mongo_node_ips_with_port = suffix(hiera('mongo_node_ips'), ':27017')
    $mongo_node_ips_with_port_nobr = suffix(hiera('mongo_node_ips'), ':27017')
  }
  $mongodb_replset = hiera('mongodb::server::replset')

  if downcase(hiera('ceilometer_backend')) == 'mongodb' {
    include ::mongodb::globals
    include ::mongodb::client
    class { '::mongodb::server' :
      service_manage => false,
    }

    if $pacemaker_master {
      pacemaker::resource::service { $::mongodb::params::service_name :
        op_params          => 'start timeout=370s stop timeout=200s',
        clone_params       => true,
        post_success_sleep => 30,
        require            => Class['::mongodb::server'],
        before             => Class['::mysql::server'],
      }
      # NOTE (spredzy) : The replset can only be run
      # once all the nodes have joined the cluster.
      mongodb_conn_validator { $mongo_node_ips_with_port :
        timeout => '600',
        require => Pacemaker::Resource::Service[$::mongodb::params::service_name],
        before  => Mongodb_replset[$mongodb_replset],
      }
      mongodb_replset { $mongodb_replset :
        members => $mongo_node_ips_with_port_nobr,
      }
    }
  }

  # Memcached
  class {'::memcached' :
    service_manage => false,
  }

  # Redis
  class { '::redis' :
    service_manage => false,
    notify_service => false,
  }

  # Galera
  if str2bool(hiera('enable_galera', true)) {
    $mysql_config_file = '/etc/my.cnf.d/galera.cnf'
  } else {
    $mysql_config_file = '/etc/my.cnf.d/server.cnf'
  }
  $galera_nodes = downcase(hiera('galera_node_names', $::hostname))
  $galera_nodes_count = count(split($galera_nodes, ','))

  # FIXME: due to https://bugzilla.redhat.com/show_bug.cgi?id=1298671 we
  # set bind-address to a hostname instead of an ip address; to move Mysql
  # from internal_api on another network we'll have to customize both
  # MysqlNetwork and ControllerHostnameResolveNetwork in ServiceNetMap
  $mysql_bind_host = hiera('mysql_bind_host')
  $mysqld_options = {
    'mysqld' => {
      'skip-name-resolve'             => '1',
      'binlog_format'                 => 'ROW',
      'default-storage-engine'        => 'innodb',
      'innodb_autoinc_lock_mode'      => '2',
      'innodb_locks_unsafe_for_binlog'=> '1',
      'query_cache_size'              => '0',
      'query_cache_type'              => '0',
      'bind-address'                  => $::hostname,
      'max_connections'               => hiera('mysql_max_connections'),
      'open_files_limit'              => '-1',
      'wsrep_on'                      => 'ON',
      'wsrep_provider'                => '/usr/lib64/galera/libgalera_smm.so',
      'wsrep_cluster_name'            => 'galera_cluster',
      'wsrep_cluster_address'         => "gcomm://${galera_nodes}",
      'wsrep_slave_threads'           => '1',
      'wsrep_certify_nonPK'           => '1',
      'wsrep_max_ws_rows'             => '131072',
      'wsrep_max_ws_size'             => '1073741824',
      'wsrep_debug'                   => '0',
      'wsrep_convert_LOCK_to_trx'     => '0',
      'wsrep_retry_autocommit'        => '1',
      'wsrep_auto_increment_control'  => '1',
      'wsrep_drupal_282555_workaround'=> '0',
      'wsrep_causal_reads'            => '0',
      'wsrep_sst_method'              => 'rsync',
      'wsrep_provider_options'        => "gmcast.listen_addr=tcp://[${mysql_bind_host}]:4567;",
    },
  }

  class { '::mysql::server':
    create_root_user        => false,
    create_root_my_cnf      => false,
    config_file             => $mysql_config_file,
    override_options        => $mysqld_options,
    remove_default_accounts => $pacemaker_master,
    service_manage          => false,
    service_enabled         => false,
  }->
  exec { 'mysql-server-sleep':
    command => 'sleep 30',
    path    => "/usr/bin:/bin",
  }

  if $pacemaker_master {
    if $enable_load_balancer {
      pacemaker::resource::ocf { 'galera' :
        ocf_agent_name     => 'heartbeat:galera',
        op_params          => 'promote timeout=300s on-fail=block',
        master_params      => '',
        meta_params        => "master-max=${galera_nodes_count} ordered=true",
        resource_params    => "additional_parameters='--open-files-limit=16384' enable_creation=true wsrep_cluster_address='gcomm://${galera_nodes}'",
        post_success_sleep => 15,
        tries              => 10,
        try_sleep          => 30,
        require            => Exec['mysql-server-sleep'],
      }
    }
  }

}

if hiera('step') >= 2 {

  if $pacemaker_master {

    if $enable_load_balancer {

      include ::pacemaker::resource_defaults

      # Create an openstack-core dummy resource. See RHBZ 1290121
      pacemaker::resource::ocf { 'openstack-core':
        ocf_agent_name => 'heartbeat:Dummy',
        clone_params   => true,
      }
      # FIXME: we should not have to access tripleo::loadbalancer class
      # parameters here to configure pacemaker VIPs. The configuration
      # of pacemaker VIPs could move into puppet-tripleo or we should
      # make use of less specific hiera parameters here for the settings.
      pacemaker::resource::service { 'haproxy':
        clone_params => true,
      }

      $control_vip = hiera('tripleo::loadbalancer::controller_virtual_ip')
      if is_ipv6_address($control_vip) {
        $control_vip_netmask = '64'
      } else {
        $control_vip_netmask = '32'
      }
      pacemaker::resource::ip { 'control_vip':
        ip_address   => $control_vip,
        cidr_netmask => $control_vip_netmask,
      }
      pacemaker::constraint::base { 'control_vip-then-haproxy':
        constraint_type   => 'order',
        first_resource    => "ip-${control_vip}",
        second_resource   => 'haproxy-clone',
        first_action      => 'start',
        second_action     => 'start',
        constraint_params => 'kind=Optional',
        require           => [Pacemaker::Resource::Service['haproxy'],
                              Pacemaker::Resource::Ip['control_vip']],
      }
      pacemaker::constraint::colocation { 'control_vip-with-haproxy':
        source  => "ip-${control_vip}",
        target  => 'haproxy-clone',
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service['haproxy'],
                    Pacemaker::Resource::Ip['control_vip']],
      }

      $public_vip = hiera('tripleo::loadbalancer::public_virtual_ip')
      if is_ipv6_address($public_vip) {
        $public_vip_netmask = '64'
      } else {
        $public_vip_netmask = '32'
      }
      if $public_vip and $public_vip != $control_vip {
        pacemaker::resource::ip { 'public_vip':
          ip_address   => $public_vip,
          cidr_netmask => $public_vip_netmask,
        }
        pacemaker::constraint::base { 'public_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${public_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['public_vip']],
        }
        pacemaker::constraint::colocation { 'public_vip-with-haproxy':
          source  => "ip-${public_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['public_vip']],
        }
      }

      $redis_vip = hiera('redis_vip')
      if is_ipv6_address($redis_vip) {
        $redis_vip_netmask = '64'
      } else {
        $redis_vip_netmask = '32'
      }
      if $redis_vip and $redis_vip != $control_vip {
        pacemaker::resource::ip { 'redis_vip':
          ip_address   => $redis_vip,
          cidr_netmask => $redis_vip_netmask,
        }
        pacemaker::constraint::base { 'redis_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${redis_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['redis_vip']],
        }
        pacemaker::constraint::colocation { 'redis_vip-with-haproxy':
          source  => "ip-${redis_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['redis_vip']],
        }
      }

      $internal_api_vip = hiera('tripleo::loadbalancer::internal_api_virtual_ip')
      if is_ipv6_address($internal_api_vip) {
        $internal_api_vip_netmask = '64'
      } else {
        $internal_api_vip_netmask = '32'
      }
      if $internal_api_vip and $internal_api_vip != $control_vip {
        pacemaker::resource::ip { 'internal_api_vip':
          ip_address   => $internal_api_vip,
          cidr_netmask => $internal_api_vip_netmask,
        }
        pacemaker::constraint::base { 'internal_api_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${internal_api_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['internal_api_vip']],
        }
        pacemaker::constraint::colocation { 'internal_api_vip-with-haproxy':
          source  => "ip-${internal_api_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['internal_api_vip']],
        }
      }

      $storage_vip = hiera('tripleo::loadbalancer::storage_virtual_ip')
      if is_ipv6_address($storage_vip) {
        $storage_vip_netmask = '64'
      } else {
        $storage_vip_netmask = '32'
      }
      if $storage_vip and $storage_vip != $control_vip {
        pacemaker::resource::ip { 'storage_vip':
          ip_address   => $storage_vip,
          cidr_netmask => $storage_vip_netmask,
        }
        pacemaker::constraint::base { 'storage_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${storage_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['storage_vip']],
        }
        pacemaker::constraint::colocation { 'storage_vip-with-haproxy':
          source  => "ip-${storage_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['storage_vip']],
        }
      }

      $storage_mgmt_vip = hiera('tripleo::loadbalancer::storage_mgmt_virtual_ip')
      if is_ipv6_address($storage_mgmt_vip) {
        $storage_mgmt_vip_netmask = '64'
      } else {
        $storage_mgmt_vip_netmask = '32'
      }
      if $storage_mgmt_vip and $storage_mgmt_vip != $control_vip {
        pacemaker::resource::ip { 'storage_mgmt_vip':
          ip_address   => $storage_mgmt_vip,
          cidr_netmask => $storage_mgmt_vip_netmask,
        }
        pacemaker::constraint::base { 'storage_mgmt_vip-then-haproxy':
          constraint_type   => 'order',
          first_resource    => "ip-${storage_mgmt_vip}",
          second_resource   => 'haproxy-clone',
          first_action      => 'start',
          second_action     => 'start',
          constraint_params => 'kind=Optional',
          require           => [Pacemaker::Resource::Service['haproxy'],
                                Pacemaker::Resource::Ip['storage_mgmt_vip']],
        }
        pacemaker::constraint::colocation { 'storage_mgmt_vip-with-haproxy':
          source  => "ip-${storage_mgmt_vip}",
          target  => 'haproxy-clone',
          score   => 'INFINITY',
          require => [Pacemaker::Resource::Service['haproxy'],
                      Pacemaker::Resource::Ip['storage_mgmt_vip']],
        }
      }

    }

    pacemaker::resource::service { $::memcached::params::service_name :
      clone_params => 'interleave=true',
      require      => Class['::memcached'],
    }

    pacemaker::resource::ocf { 'rabbitmq':
      ocf_agent_name  => 'heartbeat:rabbitmq-cluster',
      resource_params => 'set_policy=\'ha-all ^(?!amq\.).* {"ha-mode":"all"}\'',
      clone_params    => 'ordered=true interleave=true',
      meta_params     => 'notify=true',
      require         => Class['::rabbitmq'],
    }


    pacemaker::resource::ocf { 'redis':
      ocf_agent_name  => 'heartbeat:redis',
      master_params   => '',
      meta_params     => 'notify=true ordered=true interleave=true',
      resource_params => 'wait_last_known_master=true',
      require         => Class['::redis'],
    }

  }

  if str2bool(hiera('opendaylight_install', 'false')) {
    $node_string = split(hiera('bootstack_nodeid'), '-')
    $controller_index = $node_string[-1]
    $ha_node_index = $controller_index + 1

    class {"opendaylight":
      extra_features => any2array(hiera('opendaylight_features', 'odl-ovsdb-openstack')),
      odl_rest_port  => hiera('opendaylight_port'),
      odl_bind_ip    => $controller_node_ips[$controller_index],
      enable_l3      => hiera('opendaylight_enable_l3', 'no'),
      enable_ha      => hiera('opendaylight_enable_ha', false),
      ha_node_ips    => split(hiera('controller_node_ips'), ','),
      ha_node_index  => $ha_node_index,
    }
  }

  if 'onos_ml2' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    # install onos and config ovs
    class {"onos":
      controllers_ip => $controller_node_ips
    }
  }

  exec { 'galera-ready' :
    command     => '/usr/bin/clustercheck >/dev/null',
    timeout     => 30,
    tries       => 180,
    try_sleep   => 10,
    environment => ['AVAILABLE_WHEN_READONLY=0'],
    require     => File['/etc/sysconfig/clustercheck'],
  }

  file { '/etc/sysconfig/clustercheck' :
    ensure  => file,
    content => "MYSQL_USERNAME=root\n
MYSQL_PASSWORD=''\n
MYSQL_HOST=localhost\n",
  }

  xinetd::service { 'galera-monitor' :
    port           => '9200',
    server         => '/usr/bin/clustercheck',
    per_source     => 'UNLIMITED',
    log_on_success => '',
    log_on_failure => 'HOST',
    flags          => 'REUSE',
    service_type   => 'UNLISTED',
    user           => 'root',
    group          => 'root',
    require        => File['/etc/sysconfig/clustercheck'],
  }

  exec { 'pcs_cleanup_1':
    command => "sleep 120; for i in $(pcs status | grep '^* ' | cut -d ' ' -f 2 | cut -d '_' -f 1 | uniq); do pcs resource cleanup $i; done",
    provider => shell,
    require => Exec['galera-ready'],
    path     => '/usr/bin:/bin:/usr/sbin:/sbin'
  } ->

  exec { 'sql-sleep':
    command => "sleep 120 && echo 'SQL Sleep complete'",
    path => "/usr/bin:/bin",
  }

  # Create all the database schemas
  if $sync_db {
    class { '::keystone::db::mysql':
      require => Exec['sql-sleep'],
    }->
    exec { 'keystone-sync-db-sleep':
      command => "sleep 5",
      path => "/usr/bin:/bin",
    }->
    class { '::glance::db::mysql':
    }->
    exec { 'glance-sync-db-sleep':
      command => "sleep 5",
      path => "/usr/bin:/bin",
    }->
    class { '::nova::db::mysql':
    }->
    exec { 'nova-sync-db-sleep':
      command => "sleep 5",
      path => "/usr/bin:/bin",
    }->
    class { '::nova::db::mysql_api':
    }->
    exec { 'nova-mysql-api-sync-db-sleep':
      command => "sleep 5",
      path => "/usr/bin:/bin",
    }->
    class { '::neutron::db::mysql':
    }->
    exec { 'neutron-sync-db-sleep':
      command => "sleep 5",
      path => "/usr/bin:/bin",
    }->
    class { '::cinder::db::mysql':
    }->
    exec { 'cinder-sync-db-sleep':
      command => "sleep 5",
      path => "/usr/bin:/bin",
    }->
    class { '::heat::db::mysql': } ->
    exec { 'heat-sync-db-sleep':
      command => "sleep 5",
      path => "/usr/bin:/bin",
    }->
    class { '::congress::db::mysql': } ->
    exec { 'congress-sync-db-sleep':
      command => "sleep 5",
      path    => "/usr/bin:/bin",
    }

    if hiera('enable_tacker') {
      class { '::tacker::db::mysql':
        require => Exec['congress-sync-db-sleep'],
      }->
      exec { 'tacker-sync-db-sleep':
        command => "sleep 5",
        path => "/usr/bin:/bin",
      }
    }

    if downcase(hiera('ceilometer_backend')) == 'mysql' {
      class { '::ceilometer::db::mysql':
        require => Class['::heat::db::mysql'],
      }
    }
    if hiera('enable_sahara') {
      class { '::sahara::db::mysql':
        require => Class['::heat::db::mysql'],
      }
    }

  }

  # pre-install swift here so we can build rings
  include ::swift



  if str2bool(hiera('enable_external_ceph', false)) {
    if str2bool(hiera('ceph_ipv6', false)) {
      $mon_host = hiera('ceph_mon_host_v6')
    } else {
      $mon_host = hiera('ceph_mon_host')
    }
    class { '::ceph::profile::params':
      mon_host            => $mon_host,
    }
    include ::ceph::conf
    include ::ceph::profile::client
  }

  if 'vpp' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    $controller_names = split(hiera('controller_node_names'), ',')
    $controller_ip = hiera('neutron::bind_host')
    class { 'etcd':
      etcd_name => $::hostname,
      listen_client_urls          => "http://$controller_ip:2379,http://$controller_ip:4001,http://localhost:4001",
      advertise_client_urls       => "http://$controller_ip:2379,http://$controller_ip:4001,http://localhost:4001",
      listen_peer_urls            => "http://$controller_ip:2380",
      initial_advertise_peer_urls => "http://$controller_ip:2380",
      initial_cluster_token       => 'etcd-cluster-1',
      proxy                       => 'off',
      initial_cluster             => regsubst($controller_names, '.+', '\0=http://\0:2380')
    }->
    exec { 'etcd-ready':
      command     => '/bin/etcdctl cluster-health >/dev/null',
      timeout     => 30,
      tries       => 5,
      try_sleep   => 10,
    }
  }


} #END STEP 2

if hiera('step') >= 3 {

  class { '::keystone':
    sync_db          => $sync_db,
    manage_service   => false,
    enabled          => false,
    enable_bootstrap => $pacemaker_master,
  }
  include ::keystone::config

  #TODO: need a cleanup-keystone-tokens.sh solution here

  file { [ '/etc/keystone/ssl', '/etc/keystone/ssl/certs', '/etc/keystone/ssl/private' ]:
    ensure  => 'directory',
    owner   => 'keystone',
    group   => 'keystone',
    require => Package['keystone'],
  }
  file { '/etc/keystone/ssl/certs/signing_cert.pem':
    content => hiera('keystone_signing_certificate'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/certs'],
  }
  file { '/etc/keystone/ssl/private/signing_key.pem':
    content => hiera('keystone_signing_key'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/private'],
  }
  file { '/etc/keystone/ssl/certs/ca.pem':
    content => hiera('keystone_ca_certificate'),
    owner   => 'keystone',
    group   => 'keystone',
    notify  => Service['keystone'],
    require => File['/etc/keystone/ssl/certs'],
  }

  $glance_backend = downcase(hiera('glance_backend', 'swift'))
  case $glance_backend {
      'swift': { $backend_store = 'glance.store.swift.Store' }
      'file': { $backend_store = 'glance.store.filesystem.Store' }
      'rbd': { $backend_store = 'glance.store.rbd.Store' }
      default: { fail('Unrecognized glance_backend parameter.') }
  }
  $http_store = ['glance.store.http.Store']
  $glance_store = concat($http_store, $backend_store)

  if $glance_backend == 'file' and hiera('glance_file_pcmk_manage', false) {
    $secontext = 'context="system_u:object_r:glance_var_lib_t:s0"'
    pacemaker::resource::filesystem { 'glance-fs':
      device       => hiera('glance_file_pcmk_device'),
      directory    => hiera('glance_file_pcmk_directory'),
      fstype       => hiera('glance_file_pcmk_fstype'),
      fsoptions    => join([$secontext, hiera('glance_file_pcmk_options', '')],','),
      clone_params => '',
    }
  }

  # TODO: notifications, scrubber, etc.
  include ::glance
  include ::glance::config
  class { '::glance::api':
    known_stores   => $glance_store,
    manage_service => false,
    enabled        => false,
  }
  class { '::glance::registry' :
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  include ::glance::notify::rabbitmq
  include join(['::glance::backend::', $glance_backend])

  $nova_ipv6 = hiera('nova::use_ipv6', false)
  if $nova_ipv6 {
    $memcached_servers = suffix(hiera('memcache_node_ips_v6'), ':11211')
  } else {
    $memcached_servers = suffix(hiera('memcache_node_ips'), ':11211')
  }

  class { '::nova' :
    memcached_servers => $memcached_servers
  }

  include ::nova::config

  class { '::nova::api' :
    sync_db        => $sync_db,
    sync_db_api    => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::cert' :
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::conductor' :
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::consoleauth' :
    manage_service => false,
    enabled        => false,
  }
  class { '::nova::vncproxy' :
    manage_service => false,
    enabled        => false,
  }
  include ::nova::scheduler::filter
  class { '::nova::scheduler' :
    manage_service => false,
    enabled        => false,
  }
  include ::nova::network::neutron

  nova_config {
    'DEFAULT/my_ip':                     value => $ipaddress;
    'DEFAULT/host':                      value => $fqdn;
  }

  if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {

    # TODO(devvesa) provide non-controller ips for these services
    $zookeeper_node_ips = hiera('neutron_api_node_ips')
    $cassandra_node_ips = hiera('neutron_api_node_ips')

    # Run zookeeper in the controller if configured
    if hiera('enable_zookeeper_on_controller') {
      class {'::tripleo::cluster::zookeeper':
        zookeeper_server_ips => $zookeeper_node_ips,
        # TODO: create a 'bind' hiera key for zookeeper
        zookeeper_client_ip  => hiera('neutron::bind_host'),
        zookeeper_hostnames  => split(hiera('controller_node_names'), ',')
      }
    }

    # Run cassandra in the controller if configured
    if hiera('enable_cassandra_on_controller') {
      class {'::tripleo::cluster::cassandra':
        cassandra_servers => $cassandra_node_ips,
        # TODO: create a 'bind' hiera key for cassandra
        cassandra_ip      => hiera('neutron::bind_host'),
      }
    }

    class {'::tripleo::network::midonet::agent':
      zookeeper_servers => $zookeeper_node_ips,
      cassandra_seeds   => $cassandra_node_ips
    }

    class {'::tripleo::network::midonet::api':
      zookeeper_servers    => $zookeeper_node_ips,
      vip                  => hiera('tripleo::loadbalancer::public_virtual_ip'),
      keystone_ip          => hiera('tripleo::loadbalancer::public_virtual_ip'),
      keystone_admin_token => hiera('keystone::admin_token'),
      # TODO: create a 'bind' hiera key for api
      bind_address         => hiera('neutron::bind_host'),
      admin_password       => hiera('admin_password')
    }

    # Configure Neutron
    class {'::neutron':
      service_plugins => []
    }

  }
  else {
    # Neutron class definitions
    include ::neutron
  }

  include ::neutron::config

  neutron_config {
    'DEFAULT/host': value => $fqdn;
  }

  class { '::neutron::server' :
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  include ::neutron::server::notifications
  if  hiera('neutron::core_plugin') == 'neutron.plugins.nuage.plugin.NuagePlugin' {
    include ::neutron::plugins::nuage
  }
  if  hiera('neutron::core_plugin') == 'neutron_plugin_contrail.plugins.opencontrail.contrail_plugin.NeutronPluginContrailCoreV2' {
    include ::neutron::plugins::opencontrail
  }
  if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {
    class {'::neutron::plugins::midonet':
      midonet_api_ip    => hiera('tripleo::loadbalancer::public_virtual_ip'),
      keystone_tenant   => hiera('neutron::server::auth_tenant'),
      keystone_password => hiera('neutron::server::auth_password')
    }
  }
  if hiera('neutron::core_plugin') == 'networking_plumgrid.neutron.plugins.plugin.NeutronPluginPLUMgridV2' {
    class { '::neutron::plugins::plumgrid' :
      connection                   => hiera('neutron::server::database_connection'),
      controller_priv_host         => hiera('keystone_admin_api_vip'),
      admin_password               => hiera('admin_password'),
      metadata_proxy_shared_secret => hiera('nova::api::neutron_metadata_proxy_shared_secret'),
    }
  }
  if hiera('neutron::enable_dhcp_agent',true) {
    class { '::neutron::agents::dhcp' :
      manage_service => false,
      enabled        => false,
    }
    file { '/etc/neutron/dnsmasq-neutron.conf':
      content => hiera('neutron_dnsmasq_options', ''),
      owner   => 'neutron',
      group   => 'neutron',
      notify  => Service['neutron-dhcp-service'],
      require => Package['neutron'],
    }
  }

  if hiera('neutron::enable_metadata_agent',true) {
    class { '::neutron::agents::metadata':
      manage_service => false,
      enabled        => false,
    }
  }
  include ::neutron::plugins::ml2

  if 'cisco_ucsm' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    include ::neutron::plugins::ml2::cisco::ucsm
  }
  if 'cisco_nexus' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    include ::neutron::plugins::ml2::cisco::nexus
    include ::neutron::plugins::ml2::cisco::type_nexus_vxlan
  }
  if 'cisco_n1kv' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    include ::neutron::plugins::ml2::cisco::nexus1000v

    class { '::neutron::agents::n1kv_vem':
      n1kv_source  => hiera('n1kv_vem_source', undef),
      n1kv_version => hiera('n1kv_vem_version', undef),
    }

    class { '::n1k_vsm':
      n1kv_source  => hiera('n1kv_vsm_source', undef),
      n1kv_version => hiera('n1kv_vsm_version', undef),
    }
  }

  if 'bsn_ml2' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    include ::neutron::plugins::ml2::bigswitch::restproxy
    include ::neutron::agents::bigswitch
  }

  if ! empty(grep(hiera('neutron::plugins::ml2::mechanism_drivers'), 'opendaylight')) {
    if str2bool(hiera('opendaylight_install', 'false')) {
      $controller_ips = split(hiera('controller_node_ips'), ',')
      if hiera('opendaylight_enable_ha', false) {
        $odl_ovsdb_iface = "tcp:${controller_ips[0]}:6640 tcp:${controller_ips[1]}:6640 tcp:${controller_ips[2]}:6640"
        # Workaround to work with current puppet-neutron
        # This isn't the best solution, since the odl check URL ends up being only the first node in HA case
        $opendaylight_controller_ip = $controller_ips[0]
        # Bug where netvirt:1 doesn't come up right with HA
        # Check ovsdb:1 instead
        $net_virt_url = 'restconf/operational/network-topology:network-topology/topology/ovsdb:1'
        $odl_vip = hiera('opendaylight_api_vip')
        if ! $odl_vip {
          fail('ODL VIP not set in hiera or empty')
        }
        $odl_ml2_ip = $odl_vip
      } else {
        $opendaylight_controller_ip = $controller_ips[0]
        $odl_ovsdb_iface = "tcp:${opendaylight_controller_ip}:6640"
        $net_virt_url = 'restconf/operational/network-topology:network-topology/topology/netvirt:1'
        $odl_ml2_ip = $opendaylight_controller_ip
      }
    } else {
      $opendaylight_controller_ip = hiera('opendaylight_controller_ip')
      $odl_ovsdb_iface = "tcp:${opendaylight_controller_ip}:6640"
      $net_virt_url = 'restconf/operational/network-topology:network-topology/topology/netvirt:1'
      $odl_ml2_ip = $opendaylight_controller_ip
    }

    $opendaylight_port = hiera('opendaylight_port')
    $private_ip = hiera('neutron::agents::ml2::ovs::local_ip')
    $opendaylight_url = "http://${opendaylight_controller_ip}:${opendaylight_port}/${net_virt_url}"

    class { '::neutron::plugins::ml2::opendaylight':
      odl_username  => hiera('opendaylight_username'),
      odl_password  => hiera('opendaylight_password'),
      odl_url => "http://${odl_ml2_ip}:${opendaylight_port}/controller/nb/v2/neutron";
    }
    # TODO (trozet) fix SDNVPN for ODL HA
    if hiera('opendaylight_features', 'odl-ovsdb-openstack') =~ /odl-vpnservice-openstack/ {
      $odl_tunneling_ip = hiera('neutron::agents::ml2::ovs::local_ip')
      $private_network = hiera('neutron_tenant_network')
      $cidr_arr = split($private_network, '/')
      $private_mask = $cidr_arr[1]
      $private_subnet = inline_template("<%= require 'ipaddr'; IPAddr.new('$private_network').mask('$private_mask') -%>")
      $odl_port = hiera('opendaylight_port')
      $file_setupTEPs = '/tmp/setup_TEPs.py'
      $astute_yaml = "network_metadata:
  vips:
    management:
      ipaddr: ${opendaylight_controller_ip}
opendaylight:
  rest_api_port: ${odl_port}
  bgpvpn_gateway: 11.0.0.254
private_network_range: ${private_subnet}/${private_mask}"

      file { '/etc/astute.yaml':
        content => $astute_yaml,
      }
      exec { 'setup_TEPs':
        # At the moment the connection between ovs and ODL is no HA if vpnfeature is activated
        command => "python $file_setupTEPs $opendaylight_controller_ip $odl_tunneling_ip $odl_ovsdb_iface",
        require => File['/etc/astute.yaml'],
        path => '/usr/local/bin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/sbin',
      }
    } elsif hiera('fdio', false) {
      $odl_username  = hiera('opendaylight_username')
      $odl_password  = hiera('opendaylight_password')
      $ctrlplane_interface = hiera('nic1')
      if ! $ctrlplane_interface { fail("Cannot map logical interface NIC1 to physical interface")}
      $vpp_ip = inline_template("<%= scope.lookupvar('::ipaddress_${ctrlplane_interface}') -%>")
      $fdio_data_template='{"node" : [{"node-id":"<%= @fqdn %>","netconf-node-topology:host":"<%= @vpp_ip %>","netconf-node-topology:port":"2831","netconf-node-topology:tcp-only":false,"netconf-node-topology:keepalive-delay":0,"netconf-node-topology:username":"<%= @odl_username %>","netconf-node-topology:password":"<%= @odl_password %>","netconf-node-topology:connection-timeout-millis":10000,"netconf-node-topology:default-request-timeout-millis":10000,"netconf-node-topology:max-connection-attempts":10,"netconf-node-topology:between-attempts-timeout-millis":10000,"netconf-node-topology:schema-cache-directory":"hcmount"}]}'
      $fdio_data = inline_template($fdio_data_template)
      $fdio_url = "http://${opendaylight_controller_ip}:${opendaylight_port}/restconf/config/network-topology:network-topology/network-topology:topology/topology-netconf/node/${fqdn}"
      exec { 'VPP Mount into ODL':
        command   => "curl -o /dev/null --fail --silent -u ${odl_username}:${odl_password} ${fdio_url} -i -H 'Content-Type: application/json' --data \'${fdio_data}\' -X PUT",
        tries     => 5,
        try_sleep => 30,
        path      => '/usr/sbin:/usr/bin:/sbin:/bin',
      }

      # TODO(trozet): configure OVS here for br-ex with L3 AGENT

    } else {
      class { '::neutron::plugins::ovs::opendaylight':
        tunnel_ip             => $private_ip,
        odl_username          => hiera('opendaylight_username'),
        odl_password          => hiera('opendaylight_password'),
        odl_check_url         => $opendaylight_url,
        odl_ovsdb_iface       => $odl_ovsdb_iface,
      }
    }
    if ! str2bool(hiera('opendaylight_enable_l3', 'no')) {
      class { '::neutron::agents::l3' :
        manage_service => false,
        enabled        => false,
      }
    }
  } elsif 'onos_ml2' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    #config ml2_conf.ini with onos url address
    $onos_port = hiera('onos_port')
    $private_ip = hiera('neutron::agents::ml2::ovs::local_ip')

    neutron_plugin_ml2 {
      'onos/username':         value => 'admin';
      'onos/password':         value => 'admin';
      'onos/url_path':         value => "http://${controller_node_ips[0]}:${onos_port}/onos/vtn";
    }
  } elsif 'vpp' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    $tenant_nic = hiera('tenant_nic')
    $dpdk_tenant_port = hiera("${tenant_nic}", $tenant_nic)
    if ! $dpdk_tenant_port { fail("Cannot find physical port name for logical port ${dpdk_tenant_port}")}

    $tenant_nic_vpp_str = hiera("${dpdk_tenant_port}_vpp_str", false)
    if ! $tenant_nic_vpp_str { fail("Cannot find vpp_str for tenant nic ${dpdk_tenant_port}")}

    $tenant_vpp_int = inline_template("<%= `vppctl show int | grep $tenant_nic_vpp_str | awk {'print \$1'}`.chomp -%>")
    if ! $tenant_vpp_int { fail("VPP interface not found for $tenant_nic_vpp_str")}

    class { '::neutron::plugins::ml2::networking-vpp':
      etcd_host => $controller_ip,
    }->
    class {'::neutron::agents::ml2::networking-vpp':
      physnets  => "datacentre:$tenant_vpp_int",
      etcd_host => $controller_ip,
    }
  } else {
    class { '::neutron::agents::l3' :
      manage_service => false,
      enabled        => false,
    }
    class { 'neutron::agents::ml2::ovs':
      manage_service   => false,
      enabled          => false,
    }
  }
  if !('onos_ml2' in hiera('neutron::plugins::ml2::mechanism_drivers') or str2bool(hiera('opendaylight_enable_l3', 'no'))) {
    neutron_l3_agent_config {
      'DEFAULT/ovs_use_veth': value => hiera('neutron_ovs_use_veth', false);
    }
  }
  neutron_dhcp_agent_config {
    'DEFAULT/ovs_use_veth': value => hiera('neutron_ovs_use_veth', false);
  }
  neutron_config {
    'DEFAULT/notification_driver': value => 'messaging';
  }

  include ::cinder
  include ::cinder::config
  include ::tripleo::ssl::cinder_config
  class { '::cinder::api':
    sync_db        => $sync_db,
    manage_service => false,
    enabled        => false,
  }
  class { '::cinder::scheduler' :
    manage_service => false,
    enabled        => false,
  }
  class { '::cinder::volume' :
    manage_service => false,
    enabled        => false,
  }
  include ::cinder::glance
  include ::cinder::ceilometer
  class { '::cinder::setup_test_volume':
    size => join([hiera('cinder_lvm_loop_device_size'), 'M']),
  }

  $cinder_enable_iscsi = hiera('cinder_enable_iscsi_backend', true)
  if $cinder_enable_iscsi {
    $cinder_iscsi_backend = 'tripleo_iscsi'

    cinder::backend::iscsi { $cinder_iscsi_backend :
      iscsi_ip_address => hiera('cinder_iscsi_ip_address'),
      iscsi_helper     => hiera('cinder_iscsi_helper'),
    }
  }

  if $enable_ceph {

    $ceph_pools = hiera('ceph_pools')
    ceph::pool { $ceph_pools :
      pg_num  => hiera('ceph::profile::params::osd_pool_default_pg_num'),
      pgp_num => hiera('ceph::profile::params::osd_pool_default_pgp_num'),
      size    => hiera('ceph::profile::params::osd_pool_default_size'),
    }

    $cinder_pool_requires = [Ceph::Pool[hiera('cinder_rbd_pool_name')]]

  } else {
    $cinder_pool_requires = []
  }

  if hiera('cinder_enable_rbd_backend', false) {
    $cinder_rbd_backend = 'tripleo_ceph'

    cinder::backend::rbd { $cinder_rbd_backend :
      rbd_pool        => hiera('cinder_rbd_pool_name'),
      rbd_user        => hiera('ceph_client_user_name'),
      rbd_secret_uuid => hiera('ceph::profile::params::fsid'),
      require         => $cinder_pool_requires,
    }
  }

  if hiera('cinder_enable_eqlx_backend', false) {
    $cinder_eqlx_backend = hiera('cinder::backend::eqlx::volume_backend_name')

    cinder::backend::eqlx { $cinder_eqlx_backend :
      volume_backend_name => hiera('cinder::backend::eqlx::volume_backend_name', undef),
      san_ip              => hiera('cinder::backend::eqlx::san_ip', undef),
      san_login           => hiera('cinder::backend::eqlx::san_login', undef),
      san_password        => hiera('cinder::backend::eqlx::san_password', undef),
      san_thin_provision  => hiera('cinder::backend::eqlx::san_thin_provision', undef),
      eqlx_group_name     => hiera('cinder::backend::eqlx::eqlx_group_name', undef),
      eqlx_pool           => hiera('cinder::backend::eqlx::eqlx_pool', undef),
      eqlx_use_chap       => hiera('cinder::backend::eqlx::eqlx_use_chap', undef),
      eqlx_chap_login     => hiera('cinder::backend::eqlx::eqlx_chap_login', undef),
      eqlx_chap_password  => hiera('cinder::backend::eqlx::eqlx_san_password', undef),
    }
  }

  if hiera('cinder_enable_dellsc_backend', false) {
    $cinder_dellsc_backend = hiera('cinder::backend::dellsc_iscsi::volume_backend_name')

    cinder::backend::dellsc_iscsi{ $cinder_dellsc_backend :
      volume_backend_name   => hiera('cinder::backend::dellsc_iscsi::volume_backend_name', undef),
      san_ip                => hiera('cinder::backend::dellsc_iscsi::san_ip', undef),
      san_login             => hiera('cinder::backend::dellsc_iscsi::san_login', undef),
      san_password          => hiera('cinder::backend::dellsc_iscsi::san_password', undef),
      dell_sc_ssn           => hiera('cinder::backend::dellsc_iscsi::dell_sc_ssn', undef),
      iscsi_ip_address      => hiera('cinder::backend::dellsc_iscsi::iscsi_ip_address', undef),
      iscsi_port            => hiera('cinder::backend::dellsc_iscsi::iscsi_port', undef),
      dell_sc_api_port      => hiera('cinder::backend::dellsc_iscsi::dell_sc_api_port', undef),
      dell_sc_server_folder => hiera('cinder::backend::dellsc_iscsi::dell_sc_server_folder', undef),
      dell_sc_volume_folder => hiera('cinder::backend::dellsc_iscsi::dell_sc_volume_folder', undef),
    }
  }

  if hiera('cinder_enable_netapp_backend', false) {
    $cinder_netapp_backend = hiera('cinder::backend::netapp::title')

    if hiera('cinder::backend::netapp::nfs_shares', undef) {
      $cinder_netapp_nfs_shares = split(hiera('cinder::backend::netapp::nfs_shares', undef), ',')
    }

    cinder::backend::netapp { $cinder_netapp_backend :
      netapp_login                 => hiera('cinder::backend::netapp::netapp_login', undef),
      netapp_password              => hiera('cinder::backend::netapp::netapp_password', undef),
      netapp_server_hostname       => hiera('cinder::backend::netapp::netapp_server_hostname', undef),
      netapp_server_port           => hiera('cinder::backend::netapp::netapp_server_port', undef),
      netapp_size_multiplier       => hiera('cinder::backend::netapp::netapp_size_multiplier', undef),
      netapp_storage_family        => hiera('cinder::backend::netapp::netapp_storage_family', undef),
      netapp_storage_protocol      => hiera('cinder::backend::netapp::netapp_storage_protocol', undef),
      netapp_transport_type        => hiera('cinder::backend::netapp::netapp_transport_type', undef),
      netapp_vfiler                => hiera('cinder::backend::netapp::netapp_vfiler', undef),
      netapp_volume_list           => hiera('cinder::backend::netapp::netapp_volume_list', undef),
      netapp_vserver               => hiera('cinder::backend::netapp::netapp_vserver', undef),
      netapp_partner_backend_name  => hiera('cinder::backend::netapp::netapp_partner_backend_name', undef),
      nfs_shares                   => $cinder_netapp_nfs_shares,
      nfs_shares_config            => hiera('cinder::backend::netapp::nfs_shares_config', undef),
      netapp_copyoffload_tool_path => hiera('cinder::backend::netapp::netapp_copyoffload_tool_path', undef),
      netapp_controller_ips        => hiera('cinder::backend::netapp::netapp_controller_ips', undef),
      netapp_sa_password           => hiera('cinder::backend::netapp::netapp_sa_password', undef),
      netapp_storage_pools         => hiera('cinder::backend::netapp::netapp_storage_pools', undef),
      netapp_eseries_host_type     => hiera('cinder::backend::netapp::netapp_eseries_host_type', undef),
      netapp_webservice_path       => hiera('cinder::backend::netapp::netapp_webservice_path', undef),
    }
  }

  if hiera('cinder_enable_nfs_backend', false) {
    $cinder_nfs_backend = 'tripleo_nfs'

    if str2bool($::selinux) {
      selboolean { 'virt_use_nfs':
        value      => on,
        persistent => true,
      } -> Package['nfs-utils']
    }

    package { 'nfs-utils': } ->
    cinder::backend::nfs { $cinder_nfs_backend:
      nfs_servers       => hiera('cinder_nfs_servers'),
      nfs_mount_options => hiera('cinder_nfs_mount_options',''),
      nfs_shares_config => '/etc/cinder/shares-nfs.conf',
    }
  }

  $cinder_enabled_backends = delete_undef_values([$cinder_iscsi_backend, $cinder_rbd_backend, $cinder_eqlx_backend, $cinder_dellsc_backend, $cinder_netapp_backend, $cinder_nfs_backend])
  class { '::cinder::backends' :
    enabled_backends => union($cinder_enabled_backends, hiera('cinder_user_enabled_backends')),
  }
  if hiera('enable_sahara') {
    class { '::sahara':
      sync_db => $sync_db,
    }

    class { '::sahara::service::api':
      manage_service => false,
      enabled        => false,
    }
    class { '::sahara::service::engine':
      manage_service => false,
      enabled        => false,
    }
  }
  # swift proxy
  class { '::swift::proxy' :
    manage_service => $non_pcmk_start,
    enabled        => $non_pcmk_start,
  }
  include ::swift::proxy::proxy_logging
  include ::swift::proxy::healthcheck
  include ::swift::proxy::cache
  include ::swift::proxy::keystone
  include ::swift::proxy::authtoken
  include ::swift::proxy::staticweb
  include ::swift::proxy::ratelimit
  include ::swift::proxy::catch_errors
  include ::swift::proxy::tempurl
  include ::swift::proxy::formpost

  # swift storage
  if str2bool(hiera('enable_swift_storage', true)) {
    class {'::swift::storage::all':
      mount_check => str2bool(hiera('swift_mount_check')),
    }
    class {'::swift::storage::account':
      manage_service => $non_pcmk_start,
      enabled        => $non_pcmk_start,
    }
    class {'::swift::storage::container':
      manage_service => $non_pcmk_start,
      enabled        => $non_pcmk_start,
    }
    class {'::swift::storage::object':
      manage_service => $non_pcmk_start,
      enabled        => $non_pcmk_start,
    }
    if(!defined(File['/srv/node'])) {
      file { '/srv/node':
        ensure  => directory,
        owner   => 'swift',
        group   => 'swift',
        require => Package['openstack-swift'],
      }
    }
    $swift_components = ['account', 'container', 'object']
    swift::storage::filter::recon { $swift_components : }
    swift::storage::filter::healthcheck { $swift_components : }
  }

  if hiera('enable_tacker') {
    $tacker_init_conf = '[Unit]
Description=OpenStack Tacker Server
After=syslog.target network.target
[Service]
Type=notify
NotifyAccess=all
TimeoutStartSec=0
Restart=always
User=root
ExecStart=/etc/init.d/tacker-server start
ExecStop=/etc/init.d/tacker-server stop
[Install]
WantedBy=multi-user.target'

    file { '/usr/lib/systemd/system/openstack-tacker.service':
      ensure  => file,
      content => $tacker_init_conf,
      mode    => '0644'
    }->
    exec { 'reload_systemd':
      command => 'systemctl daemon-reload',
      path    => '/usr/sbin:/usr/bin:/sbin:/bin',
    }->
    class { '::tacker':
      sync_db => $sync_db,
      manage_service => false,
      enabled        => false,
    }
  }

  # Ceilometer
  case downcase(hiera('ceilometer_backend')) {
    /mysql/: {
      $ceilometer_database_connection = hiera('ceilometer_mysql_conn_string')
    }
    default: {
      $mongo_node_string = join($mongo_node_ips_with_port, ',')
      $ceilometer_database_connection = "mongodb://${mongo_node_string}/ceilometer?replicaSet=${mongodb_replset}"
    }
  }
  include ::ceilometer
  include ::ceilometer::config
  class { '::ceilometer::api' :
    manage_service => false,
    enabled        => false,
  }
  class { '::ceilometer::agent::notification' :
    manage_service => false,
    enabled        => false,
  }
  class { '::ceilometer::agent::central' :
    manage_service => false,
    enabled        => false,
  }
  class { '::ceilometer::collector' :
    manage_service => false,
    enabled        => false,
  }
  include ::ceilometer::expirer
  class { '::ceilometer::db' :
    database_connection => $ceilometer_database_connection,
    sync_db             => $sync_db,
  }
  include ::ceilometer::agent::auth

  Cron <| title == 'ceilometer-expirer' |> { command => "sleep $((\$(od -A n -t d -N 3 /dev/urandom) % 86400)) && ${::ceilometer::params::expirer_command}" }

  # Heat
  include ::heat::config
  class { '::heat' :
    sync_db             => $sync_db,
    notification_driver => 'messaging',
  }
  class { '::heat::api' :
    manage_service => false,
    enabled        => false,
  }
  class { '::heat::api_cfn' :
    manage_service => false,
    enabled        => false,
  }
  class { '::heat::api_cloudwatch' :
    manage_service => false,
    enabled        => false,
  }
  class { '::heat::engine' :
    manage_service => false,
    enabled        => false,
  }
  # Domain resources will be created at step5 on the pacemaker_master
  # So we configure heat.conf at step3 and 4 but actually create the domain later.
  if hiera('step') == 3 or hiera('step') == 4 {
    class { '::heat::keystone::domain':
      manage_domain => false,
      manage_user   => false,
      manage_role   => false,
    }
  }

  # httpd/apache and horizon
  # NOTE(gfidente): server-status can be consumed by the pacemaker resource agent
  class { '::apache' :
    service_enable => false,
    # service_manage => false, # <-- not supported with horizon&apache mod_wsgi?
  }
  include ::keystone::wsgi::apache
  include ::apache::mod::status
  if 'cisco_n1kv' in hiera('neutron::plugins::ml2::mechanism_drivers') {
    $_profile_support = 'cisco'
  } else {
    $_profile_support = 'None'
  }
  $neutron_options   = {'profile_support' => $_profile_support }

  $memcached_ipv6 = hiera('memcached_ipv6', false)
  if $memcached_ipv6 {
    $horizon_memcached_servers = hiera('memcache_node_ips_v6', '[::1]')
  } else {
    $horizon_memcached_servers = hiera('memcache_node_ips', '127.0.0.1')
  }

  class { '::horizon':
    cache_server_ip => $horizon_memcached_servers,
    neutron_options => $neutron_options,
  }

  # Aodh
  class { '::aodh' :
    database_connection => $ceilometer_database_connection,
  }
  include ::aodh::config
  include ::aodh::auth
  include ::aodh::client
  include ::aodh::wsgi::apache
  class { '::aodh::api':
    manage_service => false,
    enabled        => false,
    service_name   => 'httpd',
  }
  class { '::aodh::evaluator':
    manage_service => false,
    enabled        => false,
  }
  class { '::aodh::notifier':
    manage_service => false,
    enabled        => false,
  }
  class { '::aodh::listener':
    manage_service => false,
    enabled        => false,
  }

$event_pipeline = "---
sources:
    - name: event_source
      events:
          - \"*\"
      sinks:
          - event_sink
sinks:
    - name: event_sink
      transformers:
      triggers:
      publishers:
          - notifier://?topic=alarm.all
          - notifier://
"

  file { '/etc/ceilometer/event_pipeline.yaml':
    ensure  => present,
    content => $event_pipeline,
  }

  class { '::congress':
    sync_db => $sync_db,
    manage_service => false,
    enabled        => false,
  }

  $snmpd_user = hiera('snmpd_readonly_user_name')
  snmp::snmpv3_user { $snmpd_user:
    authtype => 'MD5',
    authpass => hiera('snmpd_readonly_user_password'),
  }
  class { '::snmp':
    agentaddress => ['udp:161','udp6:[::1]:161'],
    snmpd_config => [ join(['createUser ', hiera('snmpd_readonly_user_name'), ' MD5 "', hiera('snmpd_readonly_user_password'), '"']), join(['rouser ', hiera('snmpd_readonly_user_name')]), 'proc  cron', 'includeAllDisks  10%', 'master agentx', 'trapsink localhost public', 'iquerySecName internalUser', 'rouser internalUser', 'defaultMonitors yes', 'linkUpDownNotifications yes' ],
  }

  hiera_include('controller_classes')

} #END STEP 3

if hiera('step') >= 4 {
  $keystone_enable_db_purge = hiera('keystone_enable_db_purge', true)
  $nova_enable_db_purge = hiera('nova_enable_db_purge', true)
  $cinder_enable_db_purge = hiera('cinder_enable_db_purge', true)
  $heat_enable_db_purge = hiera('heat_enable_db_purge', true)

  if $keystone_enable_db_purge {
    include ::keystone::cron::token_flush
  }
  if $nova_enable_db_purge {
    include ::nova::cron::archive_deleted_rows
  }
  if $cinder_enable_db_purge {
    include ::cinder::cron::db_purge
  }
  if $heat_enable_db_purge {
    include ::heat::cron::purge_deleted
  }

  if $pacemaker_master {

    if $enable_load_balancer {
      pacemaker::constraint::base { 'haproxy-then-keystone-constraint':
        constraint_type => 'order',
        first_resource  => 'haproxy-clone',
        second_resource => 'openstack-core-clone',
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service['haproxy'],
                            Pacemaker::Resource::Ocf['openstack-core']],
      }
    }

    pacemaker::constraint::base { 'openstack-core-then-httpd-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::apache::params::service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::apache::params::service_name],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }
    pacemaker::constraint::base { 'rabbitmq-then-keystone-constraint':
      constraint_type => 'order',
      first_resource  => 'rabbitmq-clone',
      second_resource => 'openstack-core-clone',
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Ocf['rabbitmq'],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }
    pacemaker::constraint::base { 'memcached-then-openstack-core-constraint':
      constraint_type => 'order',
      first_resource  => 'memcached-clone',
      second_resource => 'openstack-core-clone',
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service['memcached'],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }
    pacemaker::constraint::base { 'galera-then-openstack-core-constraint':
      constraint_type => 'order',
      first_resource  => 'galera-master',
      second_resource => 'openstack-core-clone',
      first_action    => 'promote',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Ocf['galera'],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }

    # Cinder
    pacemaker::resource::service { $::cinder::params::api_service :
      clone_params => 'interleave=true',
      require      => Pacemaker::Resource::Ocf['openstack-core'],
    }
    pacemaker::resource::service { $::cinder::params::scheduler_service :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::cinder::params::volume_service : }

    pacemaker::constraint::base { 'keystone-then-cinder-api-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::cinder::params::api_service}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Ocf['openstack-core'],
                          Pacemaker::Resource::Service[$::cinder::params::api_service]],
    }
    pacemaker::constraint::base { 'cinder-api-then-cinder-scheduler-constraint':
      constraint_type => 'order',
      first_resource  => "${::cinder::params::api_service}-clone",
      second_resource => "${::cinder::params::scheduler_service}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                          Pacemaker::Resource::Service[$::cinder::params::scheduler_service]],
    }
    pacemaker::constraint::colocation { 'cinder-scheduler-with-cinder-api-colocation':
      source  => "${::cinder::params::scheduler_service}-clone",
      target  => "${::cinder::params::api_service}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::cinder::params::api_service],
                  Pacemaker::Resource::Service[$::cinder::params::scheduler_service]],
    }
    pacemaker::constraint::base { 'cinder-scheduler-then-cinder-volume-constraint':
      constraint_type => 'order',
      first_resource  => "${::cinder::params::scheduler_service}-clone",
      second_resource => $::cinder::params::volume_service,
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::cinder::params::scheduler_service],
                          Pacemaker::Resource::Service[$::cinder::params::volume_service]],
    }
    pacemaker::constraint::colocation { 'cinder-volume-with-cinder-scheduler-colocation':
      source  => $::cinder::params::volume_service,
      target  => "${::cinder::params::scheduler_service}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::cinder::params::scheduler_service],
                  Pacemaker::Resource::Service[$::cinder::params::volume_service]],
    }

    # Congress
    pacemaker::resource::service { $::congress::params::service_name :
      clone_params => 'interleave=true',
      require      => Pacemaker::Resource::Ocf['openstack-core'],
    }
    pacemaker::constraint::base { 'keystone-then-congress-api-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::congress::params::service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::congress::params::service_name],
        Pacemaker::Resource::Ocf['openstack-core']],
    }
    # Sahara
    if hiera('enable_sahara') {
      pacemaker::resource::service { $::sahara::params::api_service_name :
        clone_params => 'interleave=true',
        require      => Pacemaker::Resource::Ocf['openstack-core'],
      }

      pacemaker::resource::service { $::sahara::params::engine_service_name :
        clone_params => 'interleave=true',
      }
      pacemaker::constraint::base { 'keystone-then-sahara-api-constraint':
        constraint_type => 'order',
        first_resource  => 'openstack-core-clone',
        second_resource => "${::sahara::params::api_service_name}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::sahara::params::api_service_name],
          Pacemaker::Resource::Ocf['openstack-core']],
      }
    }

    # Tacker
    if hiera('enable_tacker') {
      pacemaker::resource::service { $::tacker::params::service_name :
        clone_params => 'interleave=true',
        require      => Pacemaker::Resource::Ocf['openstack-core'],
      }

      pacemaker::constraint::base { 'keystone-then-tacker-api-constraint':
        constraint_type => 'order',
        first_resource  => 'openstack-core-clone',
        second_resource => "${::tacker::params::service_name}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::tacker::params::service_name],
          Pacemaker::Resource::Ocf['openstack-core']],
      }
    }

    # Glance
    pacemaker::resource::service { $::glance::params::registry_service_name :
      clone_params => 'interleave=true',
      require      => Pacemaker::Resource::Ocf['openstack-core'],
    }
    pacemaker::resource::service { $::glance::params::api_service_name :
      clone_params => 'interleave=true',
    }

    pacemaker::constraint::base { 'keystone-then-glance-registry-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::glance::params::registry_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }
    pacemaker::constraint::base { 'glance-registry-then-glance-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::glance::params::registry_service_name}-clone",
      second_resource => "${::glance::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                          Pacemaker::Resource::Service[$::glance::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'glance-api-with-glance-registry-colocation':
      source  => "${::glance::params::api_service_name}-clone",
      target  => "${::glance::params::registry_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::glance::params::registry_service_name],
                  Pacemaker::Resource::Service[$::glance::params::api_service_name]],
    }

    if hiera('step') == 4 {
      # Neutron
      # NOTE(gfidente): Neutron will try to populate the database with some data
      # as soon as neutron-server is started; to avoid races we want to make this
      # happen only on one node, before normal Pacemaker initialization
      # https://bugzilla.redhat.com/show_bug.cgi?id=1233061
      # NOTE(emilien): we need to run this Exec only at Step 4 otherwise this exec
      # will try to start the service while it's already started by Pacemaker
      # It would result to a deployment failure since systemd would return 1 to Puppet
      # and the overcloud would fail to deploy (6 would be returned).
      # This conditional prevents from a race condition during the deployment.
      # https://bugzilla.redhat.com/show_bug.cgi?id=1290582
      exec { 'neutron-server-systemd-start-sleep' :
        command => 'systemctl start neutron-server && /usr/bin/sleep 5',
        path    => '/usr/bin',
        unless  => '/sbin/pcs resource show neutron-server',
      } ->
      pacemaker::resource::service { $::neutron::params::server_service:
        clone_params => 'interleave=true',
        require      => Pacemaker::Resource::Ocf['openstack-core']
      }
    } else {
      pacemaker::resource::service { $::neutron::params::server_service:
        clone_params => 'interleave=true',
        require      => Pacemaker::Resource::Ocf['openstack-core']
      }
    }
    if hiera('neutron::enable_l3_agent', true) {
      pacemaker::resource::service { $::neutron::params::l3_agent_service:
        clone_params => 'interleave=true',
      }
    }
    if hiera('neutron::enable_dhcp_agent', true) {
      pacemaker::resource::service { $::neutron::params::dhcp_agent_service:
        clone_params => 'interleave=true',
      }
    }
    if hiera('neutron::enable_ovs_agent', true) {
      pacemaker::resource::service { $::neutron::params::ovs_agent_service:
        clone_params => 'interleave=true',
      }
    }
    if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {
      pacemaker::resource::service {'tomcat':
        clone_params => 'interleave=true',
      }
    }
    if hiera('neutron::enable_metadata_agent', true) {
      pacemaker::resource::service { $::neutron::params::metadata_agent_service:
        clone_params => 'interleave=true',
      }
    }
    if hiera('neutron::enable_ovs_agent', true) {
      pacemaker::resource::ocf { $::neutron::params::ovs_cleanup_service:
        ocf_agent_name => 'neutron:OVSCleanup',
        clone_params   => 'interleave=true',
      }
      pacemaker::resource::ocf { 'neutron-netns-cleanup':
        ocf_agent_name => 'neutron:NetnsCleanup',
        clone_params   => 'interleave=true',
      }

      # neutron - one chain ovs-cleanup-->netns-cleanup-->ovs-agent
      pacemaker::constraint::base { 'neutron-ovs-cleanup-to-netns-cleanup-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::ovs_cleanup_service}-clone",
        second_resource => 'neutron-netns-cleanup-clone',
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Ocf[$::neutron::params::ovs_cleanup_service],
                            Pacemaker::Resource::Ocf['neutron-netns-cleanup']],
      }
      pacemaker::constraint::colocation { 'neutron-ovs-cleanup-to-netns-cleanup-colocation':
        source  => 'neutron-netns-cleanup-clone',
        target  => "${::neutron::params::ovs_cleanup_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Ocf[$::neutron::params::ovs_cleanup_service],
                    Pacemaker::Resource::Ocf['neutron-netns-cleanup']],
      }
      pacemaker::constraint::base { 'neutron-netns-cleanup-to-openvswitch-agent-constraint':
        constraint_type => 'order',
        first_resource  => 'neutron-netns-cleanup-clone',
        second_resource => "${::neutron::params::ovs_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Ocf['neutron-netns-cleanup'],
                            Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service]],
      }
      pacemaker::constraint::colocation { 'neutron-netns-cleanup-to-openvswitch-agent-colocation':
        source  => "${::neutron::params::ovs_agent_service}-clone",
        target  => 'neutron-netns-cleanup-clone',
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Ocf['neutron-netns-cleanup'],
                    Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service]],
      }
    }
    pacemaker::constraint::base { 'keystone-to-neutron-server-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::neutron::params::server_service}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Ocf['openstack-core'],
                          Pacemaker::Resource::Service[$::neutron::params::server_service]],
    }
    if hiera('neutron::enable_ovs_agent',true) {
      pacemaker::constraint::base { 'neutron-openvswitch-agent-to-dhcp-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::ovs_agent_service}-clone",
        second_resource => "${::neutron::params::dhcp_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service]],
      }
    }
    if hiera('neutron::enable_dhcp_agent',true) and hiera('neutron::enable_ovs_agent',true) {
      pacemaker::constraint::base { 'neutron-server-to-openvswitch-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::server_service}-clone",
        second_resource => "${::neutron::params::ovs_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::server_service],
                            Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service]],
    }

      pacemaker::constraint::colocation { 'neutron-openvswitch-agent-to-dhcp-agent-colocation':
        source  => "${::neutron::params::dhcp_agent_service}-clone",
        target  => "${::neutron::params::ovs_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::ovs_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service]],
      }
    }
    if hiera('neutron::enable_dhcp_agent',true) and hiera('neutron::enable_l3_agent',true) {
      pacemaker::constraint::base { 'neutron-dhcp-agent-to-l3-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::dhcp_agent_service}-clone",
        second_resource => "${::neutron::params::l3_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::l3_agent_service]]
      }
      pacemaker::constraint::colocation { 'neutron-dhcp-agent-to-l3-agent-colocation':
        source  => "${::neutron::params::l3_agent_service}-clone",
        target  => "${::neutron::params::dhcp_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::l3_agent_service]]
      }
    }
    if hiera('neutron::enable_l3_agent',true) and hiera('neutron::enable_metadata_agent',true) {
      pacemaker::constraint::base { 'neutron-l3-agent-to-metadata-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::l3_agent_service}-clone",
        second_resource => "${::neutron::params::metadata_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::l3_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]]
      }
      pacemaker::constraint::colocation { 'neutron-l3-agent-to-metadata-agent-colocation':
        source  => "${::neutron::params::metadata_agent_service}-clone",
        target  => "${::neutron::params::l3_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::l3_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]]
      }
    }
    if hiera('neutron::core_plugin') == 'midonet.neutron.plugin_v1.MidonetPluginV2' {
      #midonet-chain chain keystone-->neutron-server-->dhcp-->metadata->tomcat
      pacemaker::constraint::base { 'neutron-server-to-dhcp-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::server_service}-clone",
        second_resource => "${::neutron::params::dhcp_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::server_service],
                            Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service]],
      }
      pacemaker::constraint::base { 'neutron-dhcp-agent-to-metadata-agent-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::dhcp_agent_service}-clone",
        second_resource => "${::neutron::params::metadata_agent_service}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                            Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]],
      }
      pacemaker::constraint::base { 'neutron-metadata-agent-to-tomcat-constraint':
        constraint_type => 'order',
        first_resource  => "${::neutron::params::metadata_agent_service}-clone",
        second_resource => 'tomcat-clone',
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service],
                            Pacemaker::Resource::Service['tomcat']],
      }
      pacemaker::constraint::colocation { 'neutron-dhcp-agent-to-metadata-agent-colocation':
        source  => "${::neutron::params::metadata_agent_service}-clone",
        target  => "${::neutron::params::dhcp_agent_service}-clone",
        score   => 'INFINITY',
        require => [Pacemaker::Resource::Service[$::neutron::params::dhcp_agent_service],
                    Pacemaker::Resource::Service[$::neutron::params::metadata_agent_service]],
      }
    }
    # Nova
    pacemaker::resource::service { $::nova::params::api_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::nova::params::conductor_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::nova::params::consoleauth_service_name :
      clone_params => 'interleave=true',
      require      => Pacemaker::Resource::Ocf['openstack-core'],
    }
    pacemaker::resource::service { $::nova::params::vncproxy_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::nova::params::scheduler_service_name :
      clone_params => 'interleave=true',
    }

    pacemaker::constraint::base { 'keystone-then-nova-consoleauth-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::nova::params::consoleauth_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }
    pacemaker::constraint::base { 'nova-consoleauth-then-nova-vncproxy-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::consoleauth_service_name}-clone",
      second_resource => "${::nova::params::vncproxy_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                          Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-vncproxy-with-nova-consoleauth-colocation':
      source  => "${::nova::params::vncproxy_service_name}-clone",
      target  => "${::nova::params::consoleauth_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::consoleauth_service_name],
                  Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name]],
    }
    pacemaker::constraint::base { 'nova-vncproxy-then-nova-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::vncproxy_service_name}-clone",
      second_resource => "${::nova::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name],
                          Pacemaker::Resource::Service[$::nova::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-api-with-nova-vncproxy-colocation':
      source  => "${::nova::params::api_service_name}-clone",
      target  => "${::nova::params::vncproxy_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::vncproxy_service_name],
                  Pacemaker::Resource::Service[$::nova::params::api_service_name]],
    }
    pacemaker::constraint::base { 'nova-api-then-nova-scheduler-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::api_service_name}-clone",
      second_resource => "${::nova::params::scheduler_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::api_service_name],
                          Pacemaker::Resource::Service[$::nova::params::scheduler_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-scheduler-with-nova-api-colocation':
      source  => "${::nova::params::scheduler_service_name}-clone",
      target  => "${::nova::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::api_service_name],
                  Pacemaker::Resource::Service[$::nova::params::scheduler_service_name]],
    }
    pacemaker::constraint::base { 'nova-scheduler-then-nova-conductor-constraint':
      constraint_type => 'order',
      first_resource  => "${::nova::params::scheduler_service_name}-clone",
      second_resource => "${::nova::params::conductor_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::nova::params::scheduler_service_name],
                          Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
    }
    pacemaker::constraint::colocation { 'nova-conductor-with-nova-scheduler-colocation':
      source  => "${::nova::params::conductor_service_name}-clone",
      target  => "${::nova::params::scheduler_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::nova::params::scheduler_service_name],
                  Pacemaker::Resource::Service[$::nova::params::conductor_service_name]],
    }

    # Ceilometer and Aodh
    case downcase(hiera('ceilometer_backend')) {
      /mysql/: {
        pacemaker::resource::service { $::ceilometer::params::agent_central_service_name:
          clone_params => 'interleave=true',
          require      => Pacemaker::Resource::Ocf['openstack-core'],
        }
      }
      default: {
        pacemaker::resource::service { $::ceilometer::params::agent_central_service_name:
          clone_params => 'interleave=true',
          require      => [Pacemaker::Resource::Ocf['openstack-core'],
                          Pacemaker::Resource::Service[$::mongodb::params::service_name]],
        }
      }
    }
    pacemaker::resource::service { $::ceilometer::params::collector_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::ceilometer::params::api_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::ceilometer::params::agent_notification_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::ocf { 'delay' :
      ocf_agent_name  => 'heartbeat:Delay',
      clone_params    => 'interleave=true',
      resource_params => 'startdelay=10',
    }
    # Fedora doesn't know `require-all` parameter for constraints yet
    if $::operatingsystem == 'Fedora' {
      $redis_ceilometer_constraint_params = undef
      $redis_aodh_constraint_params = undef
    } else {
      $redis_ceilometer_constraint_params = 'require-all=false'
      $redis_aodh_constraint_params = 'require-all=false'
    }
    pacemaker::constraint::base { 'redis-then-ceilometer-central-constraint':
      constraint_type   => 'order',
      first_resource    => 'redis-master',
      second_resource   => "${::ceilometer::params::agent_central_service_name}-clone",
      first_action      => 'promote',
      second_action     => 'start',
      constraint_params => $redis_ceilometer_constraint_params,
      require           => [Pacemaker::Resource::Ocf['redis'],
                            Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name]],
    }
    pacemaker::constraint::base { 'redis-then-aodh-evaluator-constraint':
      constraint_type   => 'order',
      first_resource    => 'redis-master',
      second_resource   => "${::aodh::params::evaluator_service_name}-clone",
      first_action      => 'promote',
      second_action     => 'start',
      constraint_params => $redis_aodh_constraint_params,
      require           => [Pacemaker::Resource::Ocf['redis'],
                            Pacemaker::Resource::Service[$::aodh::params::evaluator_service_name]],
    }
    pacemaker::constraint::base { 'keystone-then-ceilometer-central-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::ceilometer::params::agent_central_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }
    pacemaker::constraint::base { 'ceilometer-central-then-ceilometer-collector-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::agent_central_service_name}-clone",
      second_resource => "${::ceilometer::params::collector_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-collector-then-ceilometer-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::collector_service_name}-clone",
      second_resource => "${::ceilometer::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::api_service_name]],
    }
    pacemaker::constraint::colocation { 'ceilometer-api-with-ceilometer-collector-colocation':
      source  => "${::ceilometer::params::api_service_name}-clone",
      target  => "${::ceilometer::params::collector_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                  Pacemaker::Resource::Service[$::ceilometer::params::collector_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-api-then-ceilometer-delay-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::api_service_name}-clone",
      second_resource => 'delay-clone',
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                          Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::colocation { 'ceilometer-delay-with-ceilometer-api-colocation':
      source  => 'delay-clone',
      target  => "${::ceilometer::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::ceilometer::params::api_service_name],
                  Pacemaker::Resource::Ocf['delay']],
    }
    # Aodh
    pacemaker::resource::service { $::aodh::params::evaluator_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::aodh::params::notifier_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::aodh::params::listener_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::constraint::base { 'aodh-delay-then-aodh-evaluator-constraint':
      constraint_type => 'order',
      first_resource  => 'delay-clone',
      second_resource => "${::aodh::params::evaluator_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::aodh::params::evaluator_service_name],
                          Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::colocation { 'aodh-evaluator-with-aodh-delay-colocation':
      source  => "${::aodh::params::evaluator_service_name}-clone",
      target  => 'delay-clone',
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::aodh::params::evaluator_service_name],
                  Pacemaker::Resource::Ocf['delay']],
    }
    pacemaker::constraint::base { 'aodh-evaluator-then-aodh-notifier-constraint':
      constraint_type => 'order',
      first_resource  => "${::aodh::params::evaluator_service_name}-clone",
      second_resource => "${::aodh::params::notifier_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::aodh::params::evaluator_service_name],
                          Pacemaker::Resource::Service[$::aodh::params::notifier_service_name]],
    }
    pacemaker::constraint::colocation { 'aodh-notifier-with-aodh-evaluator-colocation':
      source  => "${::aodh::params::notifier_service_name}-clone",
      target  => "${::aodh::params::evaluator_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::aodh::params::evaluator_service_name],
                  Pacemaker::Resource::Service[$::aodh::params::notifier_service_name]],
    }
    pacemaker::constraint::colocation { 'aodh-listener-with-aodh-evaluator-colocation':
      source  => "${::aodh::params::listener_service_name}-clone",
      target  => "${::aodh::params::evaluator_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::aodh::params::evaluator_service_name],
                  Pacemaker::Resource::Service[$::aodh::params::listener_service_name]],
    }
    if downcase(hiera('ceilometer_backend')) == 'mongodb' {
      pacemaker::constraint::base { 'mongodb-then-ceilometer-central-constraint':
        constraint_type => 'order',
        first_resource  => "${::mongodb::params::service_name}-clone",
        second_resource => "${::ceilometer::params::agent_central_service_name}-clone",
        first_action    => 'start',
        second_action   => 'start',
        require         => [Pacemaker::Resource::Service[$::ceilometer::params::agent_central_service_name],
                            Pacemaker::Resource::Service[$::mongodb::params::service_name]],
      }
    }

    # Heat
    pacemaker::resource::service { $::heat::params::api_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::heat::params::api_cloudwatch_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::heat::params::api_cfn_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::resource::service { $::heat::params::engine_service_name :
      clone_params => 'interleave=true',
    }
    pacemaker::constraint::base { 'keystone-then-heat-api-constraint':
      constraint_type => 'order',
      first_resource  => 'openstack-core-clone',
      second_resource => "${::heat::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                          Pacemaker::Resource::Ocf['openstack-core']],
    }
    pacemaker::constraint::base { 'heat-api-then-heat-api-cfn-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_service_name}-clone",
      second_resource => "${::heat::params::api_cfn_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                          Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-api-cfn-with-heat-api-colocation':
      source  => "${::heat::params::api_cfn_service_name}-clone",
      target  => "${::heat::params::api_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_service_name]],
    }
    pacemaker::constraint::base { 'heat-api-cfn-then-heat-api-cloudwatch-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_cfn_service_name}-clone",
      second_resource => "${::heat::params::api_cloudwatch_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                          Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-api-cloudwatch-with-heat-api-cfn-colocation':
      source  => "${::heat::params::api_cloudwatch_service_name}-clone",
      target  => "${::heat::params::api_cfn_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cfn_service_name],
                  Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name]],
    }
    pacemaker::constraint::base { 'heat-api-cloudwatch-then-heat-engine-constraint':
      constraint_type => 'order',
      first_resource  => "${::heat::params::api_cloudwatch_service_name}-clone",
      second_resource => "${::heat::params::engine_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                          Pacemaker::Resource::Service[$::heat::params::engine_service_name]],
    }
    pacemaker::constraint::colocation { 'heat-engine-with-heat-api-cloudwatch-colocation':
      source  => "${::heat::params::engine_service_name}-clone",
      target  => "${::heat::params::api_cloudwatch_service_name}-clone",
      score   => 'INFINITY',
      require => [Pacemaker::Resource::Service[$::heat::params::api_cloudwatch_service_name],
                  Pacemaker::Resource::Service[$::heat::params::engine_service_name]],
    }
    pacemaker::constraint::base { 'ceilometer-notification-then-heat-api-constraint':
      constraint_type => 'order',
      first_resource  => "${::ceilometer::params::agent_notification_service_name}-clone",
      second_resource => "${::heat::params::api_service_name}-clone",
      first_action    => 'start',
      second_action   => 'start',
      require         => [Pacemaker::Resource::Service[$::heat::params::api_service_name],
                          Pacemaker::Resource::Service[$::ceilometer::params::agent_notification_service_name]],
    }

    # Horizon and Keystone
    pacemaker::resource::service { $::apache::params::service_name:
      clone_params     => 'interleave=true',
      verify_on_create => true,
      require          => [File['/etc/keystone/ssl/certs/ca.pem'],
      File['/etc/keystone/ssl/private/signing_key.pem'],
      File['/etc/keystone/ssl/certs/signing_cert.pem']],
    }

    #VSM
    if 'cisco_n1kv' in hiera('neutron::plugins::ml2::mechanism_drivers') {
      pacemaker::resource::ocf { 'vsm-p' :
        ocf_agent_name  => 'heartbeat:VirtualDomain',
        resource_params => 'force_stop=true config=/var/spool/cisco/vsm/vsm_primary_deploy.xml',
        require         => Class['n1k_vsm'],
        meta_params     => 'resource-stickiness=INFINITY',
      }
      if str2bool(hiera('n1k_vsm::pacemaker_control', true)) {
        pacemaker::resource::ocf { 'vsm-s' :
          ocf_agent_name  => 'heartbeat:VirtualDomain',
          resource_params => 'force_stop=true config=/var/spool/cisco/vsm/vsm_secondary_deploy.xml',
          require         => Class['n1k_vsm'],
          meta_params     => 'resource-stickiness=INFINITY',
        }
        pacemaker::constraint::colocation { 'vsm-colocation-contraint':
          source  => 'vsm-p',
          target  => 'vsm-s',
          score   => '-INFINITY',
          require => [Pacemaker::Resource::Ocf['vsm-p'],
                      Pacemaker::Resource::Ocf['vsm-s']],
        }
      }
    }

  }

} #END STEP 4

if hiera('step') >= 5 {

  if $pacemaker_master {

    exec { 'pcs_cleanup_2':
      command => "sleep 10; for i in $(pcs status | grep '^* ' | cut -d ' ' -f 2 | cut -d '_' -f 1 | uniq); do pcs resource cleanup $i; done",
      provider => shell,
      path     => '/usr/bin:/bin:/usr/sbin:/sbin'
    } ->

    class {'::keystone::roles::admin' :
      require => Pacemaker::Resource::Service[$::apache::params::service_name],
    } ->
    class {'::keystone::endpoint' :
      require => Pacemaker::Resource::Service[$::apache::params::service_name],
    }
    include ::heat::keystone::domain
    Class['::keystone::roles::admin'] -> Class['::heat::keystone::domain']

  } else {
    # On non-master controller we don't need to create Keystone resources again
    class { '::heat::keystone::domain':
      manage_domain => false,
      manage_user   => false,
      manage_role   => false,
    }
  }

} #END STEP 5

$package_manifest_name = join(['/var/lib/tripleo/installed-packages/overcloud_controller_pacemaker', hiera('step')])
package_manifest{$package_manifest_name: ensure => present}
