#!/bin/sh
set -eu

export LDAPTLS_CACERT=/ca/ca.crt
server=ldaps://external-directory.platform-validation-dependencies.svc.cluster.local:636
admin=cn=admin,dc=kamiwaza,dc=local
reader=cn=federation-reader,ou=services,dc=kamiwaza,dc=local

until ldapsearch -x -H "$server" -D "$admin" -y /credentials/ldap-admin-password \
  -b dc=kamiwaza,dc=local -s base dn >/dev/null 2>&1; do
  sleep 2
done

# Every entry is created complete, with its password already hashed.
# `simpleSecurityObject` requires `userPassword`, so adding the federation
# reader without one is an object-class violation: the add was rejected, a
# tolerated non-zero exit hid it, and the later password modify then failed
# with "No such object" against an entry that had never been created.
user_hash="$(slappasswd -T /credentials/lab-user-password)"
reader_hash="$(slappasswd -T /credentials/ldap-bind-password)"
cat >/tmp/entries.ldif <<EOF
dn: ou=people,dc=kamiwaza,dc=local
objectClass: organizationalUnit
ou: people

dn: ou=services,dc=kamiwaza,dc=local
objectClass: organizationalUnit
ou: services

dn: uid=lab-user,ou=people,dc=kamiwaza,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
cn: Lab User
sn: User
uid: lab-user
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/lab-user
mail: lab-user@users.example.invalid
userPassword: ${user_hash}

dn: ${reader}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: federation-reader
description: Read-only federation identity
userPassword: ${reader_hash}
EOF

# -c keeps going past an entry this environment already holds, and the exit
# status is read rather than discarded: the only tolerated outcome is
# "Already exists". Anything else is a fixture that did not get built.
if ! ldapadd -x -c -H "$server" -D "$admin" -y /credentials/ldap-admin-password \
  -f /tmp/entries.ldif >/tmp/ldapadd.out 2>&1; then
  if grep '^ldap_add' /tmp/ldapadd.out | grep -qv 'Already exists'; then
    cat /tmp/ldapadd.out >&2
    exit 1
  fi
fi

# A rerun has to converge on the current passwords, because this script is
# applied again whenever the fixtures are.
cat >/tmp/passwords.ldif <<EOF
dn: uid=lab-user,ou=people,dc=kamiwaza,dc=local
changetype: modify
replace: userPassword
userPassword: ${user_hash}

dn: ${reader}
changetype: modify
replace: userPassword
userPassword: ${reader_hash}
EOF
ldapmodify -x -H "$server" -D "$admin" -y /credentials/ldap-admin-password \
  -f /tmp/passwords.ldif >/dev/null

# Read-only means read, and the shipped access control grants an ordinary
# account nothing outside its own entry: without this rule the federation
# account binds successfully and every search returns "No such object", which
# is indistinguishable from a directory that was never seeded. The rule is
# inserted ahead of the default catch-all so the later "by * none" no longer
# reaches this account, and it grants read only — the refused-write proof
# below is what holds that boundary.
cat >/tmp/reader-access.ldif <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {2}to dn.subtree="dc=kamiwaza,dc=local" by dn.exact="${reader}" read by * break
EOF
if ! ldapmodify -x -H "$server" -D cn=admin,cn=config \
  -y /credentials/ldap-admin-password \
  -f /tmp/reader-access.ldif >/tmp/reader-access.out 2>&1; then
  # "Type or value exists" is this rule already being present from an earlier
  # run. Anything else is an access-control change that did not happen.
  if ! grep -q 'Type or value exists' /tmp/reader-access.out; then
    cat /tmp/reader-access.out >&2
    exit 1
  fi
fi

ldapsearch -x -LLL -H "$server" -D "$reader" -y /credentials/ldap-bind-password \
  -b ou=people,dc=kamiwaza,dc=local '(uid=lab-user)' dn >/dev/null

cat >/tmp/refused-write.ldif <<'EOF'
dn: uid=lab-user,ou=people,dc=kamiwaza,dc=local
changetype: modify
replace: description
description: this write must be refused
EOF
if ldapmodify -x -H "$server" -D "$reader" -y /credentials/ldap-bind-password \
  -f /tmp/refused-write.ldif >/dev/null 2>&1; then
  echo "federation reader unexpectedly modified directory" >&2
  exit 1
fi
