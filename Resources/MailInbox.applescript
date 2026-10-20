use framework "Foundation"

on run argv
    set readStage to "account"
    try
        set accountID to item 1 of argv
        set mailboxName to item 2 of argv
        set requestedLimit to (item 4 of argv) as integer
        if requestedLimit is not in {10, 20, 50} then set requestedLimit to 20

        with timeout of 12 seconds
            tell application id "com.apple.mail"
                set selectedAccount to first account whose id is accountID
                set readStage to "mailbox"
                set selectedMailbox to mailbox mailboxName of selectedAccount
                set readStage to "inbox"
                if item 3 of argv is "check" then check for new mail for selectedAccount
                set messageCount to count messages of selectedMailbox
                if messageCount > requestedLimit then set messageCount to requestedLimit
                if messageCount > 0 then
                    -- Four bounded column reads, rather than four events per message.
                    -- Do not request properties: they include the full message content.
                    set messageIDs to id of messages 1 thru messageCount of selectedMailbox
                    set messageSubjects to subject of messages 1 thru messageCount of selectedMailbox
                    set messageSenders to sender of messages 1 thru messageCount of selectedMailbox
                    set messageDates to date received of messages 1 thru messageCount of selectedMailbox
                end if
            end tell
        end timeout

        set readStage to "encoding"
        set formatter to current application's NSISO8601DateFormatter's alloc()'s init()
        set entries to current application's NSMutableArray's array()
        repeat with position from 1 to messageCount
            set entry to current application's NSMutableDictionary's dictionary()
            entry's setObject:((item position of messageIDs) as text) forKey:"id"
            entry's setObject:(position - 1) forKey:"sourceIndex"
            entry's setObject:((item position of messageSubjects) as text) forKey:"subject"
            entry's setObject:((item position of messageSenders) as text) forKey:"sender"
            entry's setObject:(formatter's stringFromDate:(item position of messageDates)) forKey:"receivedDateTime"
            entries's addObject:entry
        end repeat
        set resultObject to current application's NSDictionary's dictionaryWithObject:entries forKey:"messages"
        set jsonData to current application's NSJSONSerialization's dataWithJSONObject:resultObject options:0 |error|:(missing value)
        return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
    on error number errorNumber
        -- Fixed stage names and a numeric code only; never return raw mail/error text.
        return "{\"errorNumber\":" & errorNumber & ",\"stage\":\"" & readStage & "\"}"
    end try
end run
