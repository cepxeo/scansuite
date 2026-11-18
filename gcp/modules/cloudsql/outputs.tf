output "instance_id" {
  value = google_sql_database_instance.this.id
}

output "instance_name" {
  value = google_sql_database_instance.this.name
}

output "connection_name" {
  value = google_sql_database_instance.this.connection_name
}

output "private_ip" {
  value = google_sql_database_instance.this.private_ip_address
}

output "database_name" {
  value = google_sql_database.scansuite.name
}

output "user_name" {
  value = google_sql_user.scansuite.name
}
