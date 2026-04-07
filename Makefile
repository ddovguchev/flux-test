.PHONY: run

run:
	cd vagrant && vagrant up --provider=libvirt

stop:
	cd vagrant && vagrant halt