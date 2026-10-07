terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  cloud {
    hostname     = "app.eu.terraform.io"
    organization = "hashi-strawb"

    workspaces {
      name = "agent-stats"
    }
  }
}

resource "null_resource" "machine_stats" {
  for_each = toset(["cpu", "memory", "disk", "system", "limits"])

  triggers = {
    refresh = timestamp()
  }

  provisioner "local-exec" {
    command     = "sh \"$SCRIPT_PATH\""
    interpreter = ["/bin/sh", "-c"]

    environment = {
      SCRIPT_PATH = "${path.module}/inspect-machine.sh"
      REPORT_PATH = "${path.root}/.terraform/machine-stats/${each.key}.txt"
      SECTION     = each.key
    }
  }
}

data "local_file" "machine_stats" {
  for_each = null_resource.machine_stats

  filename   = "${path.root}/.terraform/machine-stats/${each.key}.txt"
  depends_on = [null_resource.machine_stats]
}

output "machine_stats" {
  description = "CPU, memory, disk, OS, and process/container limits collected on the Terraform runner during apply."
  value       = { for section, report in data.local_file.machine_stats : section => report.content }
}
