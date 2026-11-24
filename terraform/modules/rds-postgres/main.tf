# A private PostgreSQL instance on RDS: only the given client security group may connect,
# TLS is required, and the master password is created and kept by RDS in Secrets Manager.

# --- Network: db subnets, and one rule on each side of the connection ---------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.subnet_ids
}

# No outbound rule at all: the database never starts a connection
resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "Database: PostgreSQL only from the client security group, no outbound"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_client" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the app server"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.client_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "client_to_db" {
  security_group_id            = var.client_security_group_id
  description                  = "PostgreSQL to the database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

# --- Settings: what the query investigations need to see ----------------------------------

locals {
  parameters = {
    # static: only read at start
    "shared_preload_libraries" = { value = "pg_stat_statements,auto_explain", apply_method = "pending-reboot" }

    # dynamic
    "rds.force_ssl"                 = { value = "1" }    # refuse connections without TLS
    "track_io_timing"               = { value = "1" }    # I/O times in plans and statistics
    "log_min_duration_statement"    = { value = "500" }  # log statements slower than 500 ms
    "auto_explain.log_min_duration" = { value = "500" }  # ... together with their plan
    "auto_explain.log_analyze"      = { value = "0" }    # off: it instruments every statement. On only during an investigation
    "auto_explain.log_buffers"      = { value = "1" }    # ... and buffer use
    "auto_explain.log_timing"       = { value = "0" }    # per-node timing would slow down every statement
    "log_lock_waits"                = { value = "1" }    # waits longer than deadlock_timeout (1 s)
    "log_temp_files"                = { value = "1024" } # sorts and hashes that spill more than 1 MB to disk
    "log_autovacuum_min_duration"   = { value = "1000" } # autovacuum runs longer than 1 s
  }
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-db"
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "Settings for the query investigations"

  dynamic "parameter" {
    for_each = local.parameters

    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = try(parameter.value.apply_method, "immediate")
    }
  }
}

# --- The instance -------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class
  db_name        = var.database_name

  username                    = "dbadmin"
  manage_master_user_password = true # RDS creates it in Secrets Manager; it is never in the code or the state

  storage_type      = "gp3"
  allocated_storage = var.storage_gb # can grow, but never shrink
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = var.availability_zone
  multi_az               = false
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.this.name

  # Both windows (UTC) must be inside the running hours: a stopped instance makes no backups
  backup_retention_period = var.backup_retention_days
  backup_window           = "15:00-15:30"
  maintenance_window      = "tue:10:00-tue:10:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade            = false # measurements must not change with the version
  apply_immediately                     = true
  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # free

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-db-final"
}
