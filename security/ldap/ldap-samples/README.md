# LDAP sample LDIF (`ldap-samples/`)

**Purpose:** Optional **directory content** for labs and training. These files are **not** applied by `kubectl apply -k`; operators copy them into the OpenLDAP pod and run `ldapadd` / `ldapmodify` (see **`../docs/OPERATOR_GUIDE.md`**).

| File                     | Use                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| **`bootstrap.ldif`**     | Richer entries (e.g. `title`, `manager`) on top of the minimal data loaded by the **`ldap-bootstrap-import`** Job. |
| **`user-template.ldif`** | Pattern for new users; fill placeholders, then `ldapmodify`.                                                       |

Do not treat demo passwords or DNs as production-ready.
