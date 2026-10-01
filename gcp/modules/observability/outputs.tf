output "uptime_check_id" {
  value = one(google_monitoring_uptime_check_config.web[*].uptime_check_id)
}

output "notification_channel" {
  value = one(google_monitoring_notification_channel.email[*].id)
}
