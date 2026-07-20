set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Install Ansible collections required for host playbooks')]
install-collections:
    ansible-galaxy collection install -r "{{ source_directory() }}/requirements.yml"

[confirm('Bootstrap ' + target + ' [y|N] ?')]
[doc('Bootstrap `vps` or `zeus` using its matching SSH host alias.')]
install target port="": install-collections
    case "{{ target }}" in vps) user=debian; default_port=2222 ;; zeus) user=gabrielcosi; default_port=22 ;; *) printf 'target must be vps or zeus\n' >&2; exit 2 ;; esac
    port="{{ port }}"
    port="${port:-$default_port}"
    export OP_SERVICE_ACCOUNT_TOKEN="$(op read 'op://{{ target }}/doco-cd/credential')"
    ansible-playbook -i "{{ target }}," -e ansible_user="$user" -e ansible_port="$port" "{{ source_directory() }}/{{ target }}/playbook.yaml"

[confirm('Trigger ' + target + ' doco-cd deployment [y|N] ?')]
[doc('Trigger doco-cd on `vps` or `zeus` using its matching SSH host alias.')]
deploy target port="":
    case "{{ target }}" in vps) user=debian; default_port=2222 ;; zeus) user=gabrielcosi; default_port=22 ;; *) printf 'target must be vps or zeus\n' >&2; exit 2 ;; esac
    port="{{ port }}"
    port="${port:-$default_port}"
    export OP_SERVICE_ACCOUNT_TOKEN="$(op read 'op://{{ target }}/doco-cd/credential')"
    api_key=$(vals get "ref+op://{{ target }}/doco-cd/api_secret")
    ssh -p "$port" "$user@{{ target }}" "curl --silent --fail --request POST \
      --url 'http://localhost:8080/v1/api/poll/run?wait=true' \
      --header 'content-type: application/json' \
      --header 'x-api-key: ${api_key}' \
      --data '[{\"url\": \"https://github.com/gabrielcosi/home-ops.git\"}]'"
