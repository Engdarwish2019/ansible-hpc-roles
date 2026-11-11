# -*- mode: ruby -*-
# Three-node Rocky Linux 9 lab on KVM/libvirt: head (controller + NFS) and two compute nodes.
#   vagrant up
#   ansible-playbook playbooks/site.yml --ask-vault-pass
NODES = {
  "head"       => { ip: "192.168.60.10", cpus: 2, memory: 2048 },
  "compute-01" => { ip: "192.168.60.11", cpus: 2, memory: 2048 },
  "compute-02" => { ip: "192.168.60.12", cpus: 2, memory: 2048 },
}.freeze

Vagrant.configure("2") do |config|
  config.vm.box = "generic/rocky9"
  config.vm.synced_folder ".", "/vagrant", disabled: true

  NODES.each do |name, spec|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network :private_network,
                      ip: spec[:ip],
                      libvirt__network_name: "hpc-lab",
                      libvirt__dhcp_enabled: false

      node.vm.provider :libvirt do |lv|
        lv.cpus = spec[:cpus]
        lv.memory = spec[:memory]
        lv.cpu_mode = "host-passthrough"
      end
    end
  end
end
