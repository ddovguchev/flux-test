Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"

  config.vm.provider :libvirt do |libvirt|
    libvirt.cpus = 2
    libvirt.memory = 4096
  end

  {
    "cp1" => "192.168.121.10",
    "wr1" => "192.168.121.11"
#     "wr2" => "192.168.121.12",
#     "wr3" => "192.168.121.13"
  }.each do |name, ip|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip

      node.vm.provider :libvirt do |libvirt|
        libvirt.storage :file, size: "30G"
      end
    end
  end
end
