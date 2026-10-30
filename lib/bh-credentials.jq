# Stream retained application logs; never interpret a password as shell input.
def message:
  gsub("\u001b\\[[0-?]*[ -/]*[@-~]"; "")
  | sub("^[[:alnum:]_.-]+\\s+\\|\\s?"; "")
  | . as $line
  | (try fromjson catch null) as $json
  | if ($json | type) == "object" then
      ($json.message // $json.msg // "")
    else $line end
  | if type == "string" then . else "" end;

def match_field($pattern):
  (try capture($pattern; "i") catch null) // null;

reduce inputs as $line (
  {username: "admin", username_source: "default account", password: null};
  ($line | message) as $message
  | ($message | match_field("\\binitial\\s+password(?:\\s+set\\s+to)?\\s*:\\s*(?<password>.+)$")) as $password
  | ($message | match_field("\\binitial\\s+user(?:name)?(?:\\s+set\\s+to)?\\s*:\\s*(?<username>\\S+)\\s*$")) as $username
  | if $password != null and ($password.password | test("[\u0000-\u001f\u007f]") | not)
      then .password = $password.password else . end
  | if $username != null and ($username.username | test("[\u0000-\u001f\u007f]") | not)
      then .username = $username.username | .username_source = "startup log" else . end
)
