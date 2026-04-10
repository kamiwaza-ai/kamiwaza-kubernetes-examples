# LDAP sample LDIF (`ldap-samples/`)

**Purpose:** Optional **directory content** for labs and training. These files are **not** applied by `kubectl apply -k`; operators copy them into the OpenLDAP pod and run `ldapadd` / `ldapmodify` (see **`../docs/OPERATOR_GUIDE.md`**).

| File                     | Use                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| **`bootstrap.ldif`**     | Alternative entries with richer attributes (e.g. `title`, `manager`). If the **`ldap-bootstrap-import`** Job already ran, `ldapadd -c` skips existing DNs; use before the Job or on a fresh directory. |
| **`user-template.ldif`** | Pattern for new users; fill placeholders, then `ldapmodify`.                                                       |

Do not treat demo passwords or DNs as production-ready.
