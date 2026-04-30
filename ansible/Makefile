INVENTORY := -i inventory/hosts.yml
ifneq ("$(wildcard inventory/local.yml)","")
INVENTORY += -i inventory/local.yml
endif

ANSIBLE_PLAYBOOK ?= ansible-playbook
ANSIBLE ?= ansible

.PHONY: install ping-internal check-internal apply-internal check-staging apply-staging check-production apply-production check-all

install:
	ansible-galaxy collection install -r requirements.yml

ping-internal:
	$(ANSIBLE) $(INVENTORY) internal -m ping

check-internal:
	$(ANSIBLE_PLAYBOOK) $(INVENTORY) playbooks/internal.yml --check

apply-internal:
	$(ANSIBLE_PLAYBOOK) $(INVENTORY) playbooks/internal.yml

check-staging:
	$(ANSIBLE_PLAYBOOK) $(INVENTORY) playbooks/staging.yml --check

apply-staging:
	$(ANSIBLE_PLAYBOOK) $(INVENTORY) playbooks/staging.yml

check-production:
	$(ANSIBLE_PLAYBOOK) $(INVENTORY) playbooks/production.yml --check

apply-production:
	$(ANSIBLE_PLAYBOOK) $(INVENTORY) playbooks/production.yml

check-all: check-internal check-staging check-production
