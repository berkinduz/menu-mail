use framework "Foundation"

on run argv
    set readStage to "account"
    try
        set accountID to item 1 of argv
        set mailboxName to item 2 of argv
        set wantedID to (item 3 of argv) as integer
        set messagePosition to ((item 4 of argv) as integer) + 1

        with timeout of 12 seconds
            tell application id "com.apple.mail"
                set selectedAccount to first account whose id is accountID
                set readStage to "mailbox"
                set selectedMailbox to mailbox mailboxName of selectedAccount
                set readStage to "message"
                set messageRef to a reference to message messagePosition of selectedMailbox
                set readStage to "identity"
                if id of messageRef is not wantedID then
                    -- New arrivals may have shifted the saved position.
                    set messageRef to a reference to (first message of selectedMailbox whose id is wantedID)
                end if
                set readStage to "source"
                set rawSource to source of messageRef
            end tell
        end timeout

        set readStage to "encoding"
        set resultObject to current application's NSDictionary's dictionaryWithObject:rawSource forKey:"source"
        set jsonData to current application's NSJSONSerialization's dataWithJSONObject:resultObject options:0 |error|:(missing value)
        return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
    on error number errorNumber
        -- Fixed stage names and a numeric code only; never return raw mail/error text.
        return "{\"errorNumber\":" & errorNumber & ",\"stage\":\"" & readStage & "\"}"
    end try
end run
