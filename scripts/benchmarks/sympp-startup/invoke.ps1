param(
  [Parameter(Mandatory, Position = 0)][string]$Command,
  [Parameter(ValueFromRemainingArguments)][string[]]$CommandArguments
)

& $Command @CommandArguments
exit $LASTEXITCODE
