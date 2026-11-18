# The addresses are built from their parts so they are known while planning:
# callers key IAM grants (for_each) by them, and a key that is only known after
# apply fails the plan. depends_on keeps every grant after the account exists.

output "app_service_account_email" {
  value      = "${google_service_account.app.account_id}@${var.project_id}.iam.gserviceaccount.com"
  depends_on = [google_service_account.app]
}

output "poc_service_account_email" {
  value      = "${google_service_account.poc.account_id}@${var.project_id}.iam.gserviceaccount.com"
  depends_on = [google_service_account.poc]
}

output "migrate_service_account_email" {
  value      = "${google_service_account.migrate.account_id}@${var.project_id}.iam.gserviceaccount.com"
  depends_on = [google_service_account.migrate]
}
