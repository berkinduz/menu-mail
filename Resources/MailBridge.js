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

        return JSON.stringify({ errorNumber: -1708 });
    } catch (error) {
        // Do not return raw errors: they can contain account names or message content.
        return JSON.stringify({ errorNumber: Number(error.errorNumber || -1) });
    }
}
