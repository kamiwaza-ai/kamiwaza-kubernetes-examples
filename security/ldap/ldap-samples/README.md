# LDAP sample LDIF (`ldap-samples/`)

**Purpose:** optional **directory content** for labs and training. These files are **not** applied by `kubectl apply -k`; operators copy them into the directory pod and run `ldapadd` / `ldapmodify` (see **`../docs/OPERATOR_GUIDE.md`**).

| File                     | Use                                                                                                                                                                                                    |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`bootstrap.ldif`**     | Alternative entries with richer attributes (e.g. `title`, `manager`). If the **`ldap-bootstrap-import`** Job already ran, `ldapadd -c` skips existing DNs; use before the Job or on a fresh directory. |
| **`user-template.ldif`** | Pattern for new users; fill the placeholders, then `ldapmodify`.                                                                                                                                       |

No file here carries a password. Entries are created without `userPassword`, and the credential is set afterwards with `ldappasswd`, which prompts for it rather than leaving it in a file, a shell history, or an editor backup.

The DNs and the `users.example.invalid` addresses are synthetic lab values. Replace them, along with the base DN, for anything real.
