resource "aws_dynamodb_table" "cmdb_assets" {
  name         = "${var.project_name}-CMDB_Assets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "resource_id"

  attribute {
    name = "resource_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "rca_findings" {
  name         = "${var.project_name}-RCA_Findings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "finding_id"

  attribute {
    name = "finding_id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "incidents" {
  name         = "${var.project_name}-Incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ticket_id"

  attribute {
    name = "ticket_id"
    type = "S"
  }
}

# Seed the CMDB with the one asset this demo actually has. In the full
# labs this table is populated by an AWS Config -> Lambda pipeline; for
# the weekend-scope build we seed it directly since there's only one
# resource to track.
resource "aws_dynamodb_table_item" "app_instance_cmdb_entry" {
  table_name = aws_dynamodb_table.cmdb_assets.name
  hash_key   = aws_dynamodb_table.cmdb_assets.hash_key

  item = jsonencode({
    resource_id = { S = aws_instance.app.id }
    type        = { S = "EC2Instance" }
    name        = { S = "${var.project_name}-app" }
    ssm_target  = { S = aws_instance.app.id }
  })
}
