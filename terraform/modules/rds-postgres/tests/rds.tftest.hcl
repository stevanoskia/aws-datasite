# Offline tests: the AWS provider is mocked, so nothing is created and no login is needed.

mock_provider "aws" {}

variables {
  name_prefix              = "test"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_ids               = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  availability_zone        = "eu-north-1b"
  client_security_group_id = "sg-0123456789abcdef0"
}

run "only_the_client_group_can_connect" {
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.from_client.referenced_security_group_id == var.client_security_group_id
      && aws_vpc_security_group_ingress_rule.from_client.cidr_ipv4 == null
      && aws_vpc_security_group_ingress_rule.from_client.from_port == 5432
      && aws_vpc_security_group_ingress_rule.from_client.to_port == 5432
      && aws_vpc_security_group_ingress_rule.from_client.ip_protocol == "tcp"
    )
    error_message = "Inbound must be PostgreSQL from the client security group only."
  }

  assert {
    condition     = length(aws_security_group.db.ingress) == 0 && length(aws_security_group.db.egress) == 0
    error_message = "The database security group must have no inline rules (and so no outbound)."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false && toset(aws_db_instance.this.vpc_security_group_ids) == toset([aws_security_group.db.id])
    error_message = "The database must be private and use only its own security group."
  }
}

run "data_and_password_are_protected" {
  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.deletion_protection && aws_db_instance.this.skip_final_snapshot == false
    error_message = "Encryption, deletion protection and a final snapshot are required."
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password && aws_db_instance.this.password == null
    error_message = "The master password must be managed by RDS, not by Terraform."
  }

  assert {
    condition     = anytrue([for p in aws_db_parameter_group.this.parameter : p.name == "rds.force_ssl" && p.value == "1"])
    error_message = "TLS must be required."
  }
}

run "backups_and_maintenance_run_while_the_instance_is_on" {
  assert {
    condition     = aws_db_instance.this.backup_retention_period >= 1
    error_message = "Automated backups must be on."
  }

  # on from 07:00 to 19:00 Berlin = 06:00-18:00 UTC in winter, 05:00-17:00 UTC in summer
  assert {
    condition = alltrue([
      for hour in [for t in split("-", aws_db_instance.this.backup_window) : tonumber(split(":", t)[0])] : hour >= 6 && hour < 17
    ])
    error_message = "The backup window is outside the running hours, so no backup would be made."
  }

  assert {
    condition = alltrue([
      for part in split("-", aws_db_instance.this.maintenance_window) :
      contains(["mon", "tue", "wed", "thu", "fri"], split(":", part)[0]) && tonumber(split(":", part)[1]) >= 6 && tonumber(split(":", part)[1]) < 17
    ])
    error_message = "The maintenance window is outside the running hours."
  }
}

run "query_statistics_are_on" {
  assert {
    condition = anytrue([
      for p in aws_db_parameter_group.this.parameter :
      p.name == "shared_preload_libraries" && p.apply_method == "pending-reboot"
      && length(setsubtract(["pg_stat_statements", "auto_explain"], split(",", p.value))) == 0
    ])
    error_message = "pg_stat_statements and auto_explain must be loaded (a static setting)."
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "postgres18"
    error_message = "The parameter group family must match the engine version."
  }
}

run "rejects_a_single_zone" {
  command = plan

  variables {
    subnet_ids = ["subnet-0aaaaaaaaaaaaaaaa"]
  }

  expect_failures = [var.subnet_ids]
}

run "rejects_backups_switched_off" {
  command = plan

  variables {
    backup_retention_days = 0
  }

  expect_failures = [var.backup_retention_days]
}
