// Read through Apple Mail's scripting dictionary; never access its database or credentials.
function run(argv) {
    try {
        var mail = Application("com.apple.mail");
        if (argv[0] === "accounts") {
            return JSON.stringify({ accounts: mail.accounts().filter(function (account) {
                return account.enabled();
            }).map(function (account) {
                return { id: account.id(), name: account.name() };
            }) });
        }

        var account = mail.accounts.byId(argv[1]);
        if (argv[0] === "mailboxes") {
            return JSON.stringify({ mailboxes: account.mailboxes.name() });
        }

        var mailbox = account.mailboxes.byName(argv[2]);
        if (argv[0] === "inbox") {
            if (argv[3] === "check") mail.checkForNewMail({ for: account });
            // Read only the selected number of entries from Mail's inbox collection.
            // Do not fetch dates or object references for the entire mailbox.
            var requestedLimit = Number(argv[4]);
            var limit = [10, 20, 50].indexOf(requestedLimit) >= 0 ? requestedLimit : 20;
            var count = Math.min(limit, mailbox.messages.length);
            var messages = [];
            for (var index = 0; index < count; index++) {
                var item = mailbox.messages.at(index);
                var rawSender = item.sender();
                var match = /^(.*?)\s*<([^>]+)>\s*$/.exec(rawSender);
                messages.push({
                    id: String(item.id()),
                    sourceIndex: index,
                    subject: item.subject(),
                    from: { emailAddress: { name: match ? match[1].replace(/^"|"$/g, "") : rawSender,
                        address: match ? match[2] : null } },
                    receivedDateTime: item.dateReceived().toISOString()
                });
            }
            messages.sort(function (a, b) { return b.receivedDateTime.localeCompare(a.receivedDateTime); });
            return JSON.stringify({ messages: messages });
        }
        return JSON.stringify({ errorNumber: -1708 });
    } catch (error) {
        // Do not return raw errors: they can contain account names or message content.
        return JSON.stringify({ errorNumber: Number(error.errorNumber || -1) });
    }
}
