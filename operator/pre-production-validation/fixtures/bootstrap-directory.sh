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

cat >/tmp/entries.ldif <<'EOF'
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

dn: cn=federation-reader,ou=services,dc=kamiwaza,dc=local
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: federation-reader
description: Read-only federation identity
EOF
ldapadd -x -c -H "$server" -D "$admin" -y /credentials/ldap-admin-password \
  -f /tmp/entries.ldif >/dev/null 2>&1 || true
user_hash="$(slappasswd -T /credentials/lab-user-password)"
reader_hash="$(slappasswd -T /credentials/ldap-bind-password)"
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
