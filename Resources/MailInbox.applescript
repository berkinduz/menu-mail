use framework "Foundation"

on run argv
    set readStage to "account"
    try
        set accountID to item 1 of argv
        set mailboxName to item 2 of argv
        set requestedLimit to (item 4 of argv) as integer
        if requestedLimit is not in {10, 20, 50} then set requestedLimit to 20
        set requestedOffset to 0
        if (count argv) > 4 then set requestedOffset to (item 5 of argv) as integer
        if requestedOffset < 0 then set requestedOffset to 0

        with timeout of 12 seconds
            tell application id "com.apple.mail"
                set selectedAccount to first account whose id is accountID
                set readStage to "mailbox"
                set selectedMailbox to mailbox mailboxName of selectedAccount
                set readStage to "inbox"
                if item 3 of argv is "check" then check for new mail for selectedAccount
                set totalMessages to count messages of selectedMailbox
                set totalUnread to unread count of selectedMailbox
                set firstPosition to requestedOffset + 1
                set lastPosition to requestedOffset + requestedLimit
                if lastPosition > totalMessages then set lastPosition to totalMessages
                set messageCount to lastPosition - requestedOffset
                if messageCount < 0 then set messageCount to 0
                if messageCount > 0 then
                    -- Bounded metadata columns, without fetching full message contents.
                    -- Do not request properties: they include the full message content.
                    set messageIDs to id of messages firstPosition thru lastPosition of selectedMailbox
                    set messageSubjects to subject of messages firstPosition thru lastPosition of selectedMailbox
                    set messageSenders to sender of messages firstPosition thru lastPosition of selectedMailbox
                    set messageDates to date received of messages firstPosition thru lastPosition of selectedMailbox
                    set messageReadStates to read status of messages firstPosition thru lastPosition of selectedMailbox
                    set messageStars to flagged status of messages firstPosition thru lastPosition of selectedMailbox
                end if
            end tell
        end timeout

        set readStage to "encoding"
        set formatter to current application's NSISO8601DateFormatter's alloc()'s init()
        set entries to current application's NSMutableArray's array()
        repeat with position from 1 to messageCount
            set entry to current application's NSMutableDictionary's dictionary()
            entry's setObject:((item position of messageIDs) as text) forKey:"id"
            entry's setObject:(requestedOffset + position - 1) forKey:"sourceIndex"
            entry's setObject:((item position of messageSubjects) as text) forKey:"subject"
            entry's setObject:((item position of messageSenders) as text) forKey:"sender"
            entry's setObject:(formatter's stringFromDate:(item position of messageDates)) forKey:"receivedDateTime"
            entry's setObject:((item position of messageReadStates) as boolean) forKey:"isRead"
            entry's setObject:((item position of messageStars) as boolean) forKey:"isStarred"
            entries's addObject:entry
        end repeat
        set resultObject to current application's NSMutableDictionary's dictionaryWithObject:entries forKey:"messages"
        resultObject's setObject:totalUnread forKey:"unreadCount"
        if lastPosition < totalMessages then resultObject's setObject:(lastPosition as text) forKey:"nextPageToken"
        set jsonData to current application's NSJSONSerialization's dataWithJSONObject:resultObject options:0 |error|:(missing value)
        return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
    on error number errorNumber
        -- Fixed stage names and a numeric code only; never return raw mail/error text.
        return "{\"errorNumber\":" & errorNumber & ",\"stage\":\"" & readStage & "\"}"
    end try
end run
