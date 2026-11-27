# Session Manager's preferences for the whole account and region. AWS reads them from a Session
# document with exactly this name; under any other name the settings have no effect.
# They apply to every session, port forwarding included: a tunnel without traffic ends after
# idle_session_minutes.

resource "aws_ssm_document" "session_preferences" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences"
    sessionType   = "Standard_Stream"
    inputs = {
      idleSessionTimeout          = tostring(var.idle_session_minutes)
      maxSessionDuration          = ""
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = true
      cloudWatchLogGroupName      = ""
      cloudWatchEncryptionEnabled = true
      cloudWatchStreamingEnabled  = false
      kmsKeyId                    = ""
      runAsEnabled                = false
      runAsDefaultUser            = ""
      shellProfile                = { windows = "", linux = "" }
    }
  })
}
