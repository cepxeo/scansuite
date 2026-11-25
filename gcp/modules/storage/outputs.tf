output "artifact_bucket_name" {
  value = google_storage_bucket.artifacts.name
}

output "poc_exchange_bucket_name" {
  value = google_storage_bucket.poc_exchange.name
}
