# Copyright (C) 2012-2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

package EBox::LDB;

use EBox::Samba::LdbObject;
use EBox::Samba::Credentials;
use EBox::Samba::OU;
use EBox::Samba::User;
use EBox::Samba::Contact;
use EBox::Samba::Group;
use EBox::Samba::DNS::Zone;
use EBox::Users::User;

use EBox::LDB::IdMapDb;
use EBox::Exceptions::DataNotFound;
use EBox::Exceptions::DataExists;
use EBox::Gettext;

use Net::LDAP;
use Net::LDAP::Control;
use Net::LDAP::Util qw(ldap_error_name);
use Authen::SASL qw(Perl);

use Data::Dumper;
use File::Slurp;
use File::Temp qw(:seekable);
use Error qw( :try );
use Perl6::Junction qw(any);
use Time::HiRes;

use constant LDAPI => "ldapi://%2fopt%2fsamba4%2fprivate%2fldap_priv%2fldapi" ;

use constant BUILT_IN_CONTAINERS => qw(Users Computers);

# NOTE: The list of attributes available in the different Windows Server versions
#       is documented in http://msdn.microsoft.com/en-us/library/cc223254.aspx
use constant ROOT_DSE_ATTRS => [
    'configurationNamingContext',
    'currentTime',
    'defaultNamingContext',
    'dnsHostName',
    'domainControllerFunctionality',
    'domainFunctionality',
    'dsServiceName',
    'forestFunctionality',
    'highestCommittedUSN',
    'isGlobalCatalogReady',
    'isSynchronized',
    'ldapServiceName',
    'namingContexts',
    'rootDomainNamingContext',
    'schemaNamingContext',
    'serverName',
    'subschemaSubentry',
    'supportedCapabilities',
    'supportedControl',
    'supportedLDAPPolicies',
    'supportedLDAPVersion',
    'supportedSASLMechanisms',
];

# Singleton variable
my $_instance = undef;

sub _new_instance
{
    my $class = shift;

    my $ignoredGroupsFile = EBox::Config::etc() . 's4sync-groups.ignore';
    my @lines = read_file($ignoredGroupsFile);
    chomp (@lines);
    my %ignoredGroups = map { $_ => 1 } @lines;

    my $self = {};
    $self->{ldb} = undef;
    $self->{idamp} = undef;
    $self->{ignoredGroups} = \%ignoredGroups;
    bless ($self, $class);
    return $self;
}

# Method: instance
#
#   Return a singleton instance of class <EBox::Ldap>
#
# Returns:
#
#   object of class <EBox::Ldap>
sub instance
{
    my ($self, %opts) = @_;

    unless (defined ($_instance)) {
        $_instance = EBox::LDB->_new_instance();
    }

    return $_instance;
}

# Method: idmap
#
#   Returns an instance of IdMapDb.
#
sub idmap
{
    my ($self) = @_;

    unless (defined $self->{idmap}) {
        $self->{idmap} = EBox::LDB::IdMapDb->new();
    }
    return $self->{idmap};
}

# Method: ldbCon
#
#   Returns the Net::LDAP connection used by the module
#
# Returns:
#
#   An object of class Net::LDAP whose connection has already bound
#
# Exceptions:
#
#   Internal - If connection can't be created
#
sub ldbCon
{
    my ($self) = @_;

    # Workaround to detect if connection is broken and force reconnection
    my $reconnect = 0;
    if (defined $self->{ldb}) {
        my $mesg = $self->{ldb}->search(
                base => '',
                scope => 'base',
                filter => "(cn=*)",
                );
        if (ldap_error_name($mesg) ne 'LDAP_SUCCESS') {
            $self->clearConn();
            $reconnect = 1;
        }
    }

    if (not defined $self->{ldb} or $reconnect) {
        $self->{ldb} = $self->safeConnect();
    }

    return $self->{ldb};
}

sub safeConnect
{
    my ($self) = @_;

    local $SIG{PIPE};
    $SIG{PIPE} = sub {
       EBox::warn('SIGPIPE received connecting to samba LDAP');
    };

    my $samba = EBox::Global->modInstance('samba');
    $samba->_startService() unless $samba->isRunning();

    my $error = undef;
    my $lastError = undef;
    my $maxTries = 300;
    for (my $try=1; $try<=$maxTries; $try++) {
        my $ldb = Net::LDAP->new(LDAPI);
        if (defined $ldb) {
            my $dse = $ldb->root_dse(attrs => ROOT_DSE_ATTRS);
            if (defined $dse) {
                return $ldb;
            }
        }
        $error = $@;
        EBox::warn("Could not connect to samba LDAP server: $error, retrying. ($try attempts)")   if (($try == 1) or (($try % 100) == 0));
        Time::HiRes::sleep(0.1);
    }

    throw EBox::Exceptions::External(
        __x(q|FATAL: Could not connect to samba LDAP server: {error}|,
            error => $error));
}

# Method: dn
#
#   Returns the base DN (Distinguished Name)
#
# Returns:
#
#   string - DN
#
sub dn
{
    my ($self) = @_;

    unless (defined $self->{dn}) {
        my $dse = $self->rootDse();

        $self->{dn} = $dse->get_value('defaultNamingContext');
    }

    return defined $self->{dn} ? $self->{dn} : '';
}

# Method: clearConn
#
#   Closes LDAP connection and clears DN cached value
#
sub clearConn
{
    my ($self) = @_;

    if (defined $self->{ldb}) {
        $self->{ldb}->disconnect();
    }

    delete $self->{dn};
    delete $self->{ldb};
}

# Method: search
#
#   Performs a search in the LDB database using Net::LDAP.
#
# Parameters:
#
#   args - arguments to pass to Net::LDAP->search()
#
# Exceptions:
#
#   Internal - If there is an error during the search
#
sub search
{
    my ($self, $args) = @_;

    my $ldb = $self->ldbCon();
    my $result = $ldb->search(%{$args});
    $self->_errorOnLdap($result, $args);

    return $result;
}

# Method: existsDN
#
#   Finds whether a DN exists on the database
#
# Parameters:
#
#   dn   - dn to lookup
#   relativeToBaseDN - whether the given DN is relative to the baseDN (default: false)
#
# Returns:
#
#  boolean - whether the DN exists or not
#
# Exceptions:
#
#   Internal - If there is an error during the LDAP search
#
sub existsDN
{
    my ($self, $dn, $relativeToBaseDN) = @_;
    if ($relativeToBaseDN) {
        $dn = $dn . ','  . $self->dn();
    }

    my $ldb = $self->ldbCon();
    my %args = (base => $dn, scope=>'base', filter => '(objectclass=*)');
    my $result = $ldb->search(%args);

    if (ldap_error_name($result) eq 'LDAP_NO_SUCH_OBJECT') {
        # then it does not exists
        return 0;
    } else {
        # check if there is no other error
        $self->_errorOnLdap($result, \%args);
    }

    return $result->count() > 0;
}

# Method: modify
#
#   Performs a modification in the LDB database using Net::LDAP.
#
# Parameters:
#
#   dn   - dn where to perform the modification
#   args - parameters to pass to Net::LDAP->modify()
#
# Exceptions:
#
#   Internal - If there is an error during the operation
#
sub modify
{
    my ($self, $dn, $args) = @_;

    my $ldb = $self->ldbCon();
    my $result = $ldb->modify($dn, %{$args});
    $self->_errorOnLdap($result, $args);

    return $result;
}

# Method: delete
#
#   Performs a deletion in the LDB database using Net::LDAP
#
# Parameters:
#
#   dn - dn to delete
#
# Exceptions:
#
#   Internal - If there is an error during the operation
#
sub delete
{
    my ($self, $dn) = @_;

    my $ldb = $self->ldbCon();
    my $result = $ldb->delete($dn);
    $self->_errorOnLdap($result, $dn);

    return $result;
}

# Method: add
#
#   Adds an object or attributes in the LDB database using Net::LDAP
#
# Parameters:
#
#   dn - dn to add
#   args - parameters to pass to Net::LDAP->add()
#
# Exceptions:
#
#   Internal - If there is an error during the operation
#
sub add
{
    my ($self, $dn, $args) = @_;

    my $ldb = $self->ldbCon();
    my $result = $ldb->add($dn, %{$args});
    $self->_errorOnLdap($result, $args);

    return $result;
}

# Method: _errorOnLdap
#
#   Check the result for errors
#
sub _errorOnLdap
{
    my ($self, $result, $args) = @_;

    my @frames = caller (2);
    if ($result->is_error()) {
        if ($args) {
            EBox::error( Dumper($args) );
        }
        throw EBox::Exceptions::Internal("Unknown error at " .
                                         $frames[3] . " " .
                                         $result->error);
    }
}

#############################################################################
## LDB related functions                                                   ##
#############################################################################

# Method domainSID
#
#   Get the domain SID
#
# Returns:
#
#   string - The SID string of the domain
#
sub domainSID
{
    my ($self) = @_;

    my $base = $self->dn();
    my $params = {
        base => $base,
        scope => 'base',
        filter => "(distinguishedName=$base)",
        attrs => ['objectSid'],
    };
    my $msg = $self->search($params);
    if ($msg->count() == 1) {
        my $entry = $msg->entry(0);
        # The object is not a SecurityPrincipal but a SamDomainBase. As we only query
        # for the sid, it works.
        my $object = new EBox::Samba::SecurityPrincipal(entry => $entry);
        return $object->sid();
    } else {
        throw EBox::Exceptions::DataNotFound(data => 'domain', value => $base);
    }
}

sub domainNetBiosName
{
    my ($self) = @_;

    my $realm = EBox::Global->modInstance('users')->kerberosRealm();
    my $params = {
        base => 'CN=Partitions,CN=Configuration,' . $self->dn(),
        scope => 'sub',
        filter => "(&(nETBIOSName=*)(dnsRoot=$realm))",
        attrs => ['nETBIOSName'],
    };
    my $result = $self->search($params);
    if ($result->count() == 1) {
        my $entry = $result->entry(0);
        my $name = $entry->get_value('nETBIOSName');
        return $name;
    }
    return undef;
}

sub ldapOUsToLDB
{
    my ($self) = @_;

    EBox::info('Loading Zentyal OUS into samba database');
    my $global = EBox::Global->getInstance();
    my $usersMod = $global->modInstance('users');
    my $sambaMod = $global->modInstance('samba');

    my @ous = @{ EBox::Samba::OU->orderOUList($usersMod->ous()) };
    foreach my $ou (@ous) {
        my $parent = $sambaMod->ldbObjectFromLDAPObject($ou->parent);
        if (not $parent) {
            my $dn = $ou->dn();
            throw EBox::Exceptions::External("Unable to to find the container for '$dn' in Samba");
        }
        my $name = $ou->name();
        my $parentDN = $parent->dn();

        EBox::debug("Loading OU $name into $parentDN");
        # Samba already has an specific container for this OU, ignore it.
        if (($parentDN eq $self->dn()) and (grep { $_ eq $name } BUILT_IN_CONTAINERS)) {
            EBox::debug("Ignoring OU $name given that it has a built in container");
            next;
        }

        try {
            EBox::Samba::OU->create(name => $name, parent => $parent);
        } catch EBox::Exceptions::DataExists with {
            EBox::debug("OU $name already in $parentDN on Samba database");
        } otherwise {
            my $error = shift;
            EBox::error("Error loading OU '$name' in '$parentDN': $error");
        };
    }
}

sub ldapUsersToLdb
{
    my ($self) = @_;

    EBox::info('Loading Zentyal users into samba database');
    my $global = EBox::Global->getInstance();
    my $usersMod = $global->modInstance('users');
    my $sambaMod = $global->modInstance('samba');

    my $users = $usersMod->users();
    foreach my $user (@{$users}) {
        my $parent = $sambaMod->ldbObjectFromLDAPObject($user->parent);
        if (not $parent) {
            my $dn = $user->dn();
            throw EBox::Exceptions::External("Unable to to find the container for '$dn' in Samba");
        }
        my $samAccountName = $user->get('uid');
        EBox::debug("Loading user $samAccountName");
        try {
            my %args = (
                name           => scalar ($user->get('cn')),
                samAccountName => scalar ($samAccountName),
                parent         => $parent,
                uidNumber      => scalar ($user->get('uidNumber')),
                sn             => scalar ($user->get('sn')),
                givenName      => scalar ($user->get('givenName')),
                description    => scalar ($user->get('description')),
                kerberosKeys   => $user->kerberosKeys(),
            );
            EBox::Samba::User->create(%args);
        } catch EBox::Exceptions::DataExists with {
            EBox::debug("User $samAccountName already in Samba database");
            my $sambaUser = new EBox::Samba::User(samAccountName => $samAccountName);
            $sambaUser->setCredentials($user->kerberosKeys());
            EBox::debug("Password updated for user $samAccountName");
        } otherwise {
            my $error = shift;
            EBox::error("Error loading user '$samAccountName': $error");
        };
    }
}

sub ldapContactsToLdb
{
    my ($self) = @_;

    EBox::info('Loading Zentyal contacts into samba database');
    my $global = EBox::Global->getInstance();
    my $usersMod = $global->modInstance('users');
    my $sambaMod = $global->modInstance('samba');

    my $contacts = $usersMod->contacts();
    foreach my $contact (@{$contacts}) {
        my $parent = $sambaMod->ldbObjectFromLDAPObject($contact->parent);
        if (not $parent) {
            my $dn = $contact->dn();
            throw EBox::Exceptions::External("Unable to to find the container for '$dn' in Samba");
        }

        my $parentDN = $parent->dn();
        my $name = $contact->get('cn');
        EBox::debug("Loading contact $name on $parentDN");
        try {
            my %args = (
                name        => scalar ($name),
                parent      => $parent,
                givenName   => scalar ($contact->get('givenName')),
                initials    => scalar ($contact->get('initials')),
                sn          => scalar ($contact->get('sn')),
                displayName => scalar ($contact->get('displayName')),
                description => scalar ($contact->get('description')),
                mail        => $contact->get('mail')
            );
            EBox::Samba::Contact->create(%args);
        } catch EBox::Exceptions::DataExists with {
            EBox::debug("Contact $name already in $parentDN on Samba database");
        } otherwise {
            my $error = shift;
            EBox::error("Error loading contact '$name' in '$parentDN': $error");
        };
    }
}

sub ldapGroupsToLdb
{
    my ($self) = @_;

    EBox::info('Loading Zentyal groups into samba database');
    my $global = EBox::Global->getInstance();
    my $usersMod = $global->modInstance('users');
    my $sambaMod = $global->modInstance('samba');

    my $groups = $usersMod->groups();
    foreach my $group (@{$groups}) {
        my $parent = $sambaMod->ldbObjectFromLDAPObject($group->parent);
        if (not $parent) {
            my $dn = $group->dn();
            throw EBox::Exceptions::External("Unable to to find the container for '$dn' in Samba");
        }
        my $parentDN = $parent->dn();
        my $name = $group->get('cn');
        EBox::debug("Loading group $name");
        my $sambaGroup = undef;
        try {
            my %args = (
                name => $name,
                parent => $parent,
                description => scalar ($group->get('description')),
            );
            if ($group->isSecurityGroup()) {
                $args{gidNumber} = scalar ($group->get('gidNumber'));
                $args{isSecurityGroup} = $group->isSecurityGroup();
            };
            $sambaGroup = EBox::Samba::Group->create(%args);
        } catch EBox::Exceptions::DataExists with {
            EBox::debug("Group $name already in Samba database");
        } otherwise {
            my $error = shift;
            EBox::error("Error loading group '$name': $error");
        };
        next unless defined $sambaGroup;

        foreach my $user (@{$group->users()}) {
            try {
                my $smbUser = new EBox::Samba::User(samAccountName => $user->get('uid'));
                next unless defined $smbUser;
                $sambaGroup->addMember($smbUser, 1);
            } otherwise {
                my $error = shift;
                EBox::error("Error adding member: $error");
            };
        }
        $sambaGroup->save();
    }
}

sub ldapServicePrincipalsToLdb
{
    my ($self) = @_;

    EBox::info('Loading Zentyal service principals into samba database');
    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $hostname = $sysinfo->hostName();
    my $fqdn = $sysinfo->fqdn();

    my $modules = EBox::Global->modInstancesOfType('EBox::KerberosModule');
    my $usersMod = EBox::Global->modInstance('users');
    my $sambaMod = EBox::Global->modInstance('samba');

    my $baseDn = $usersMod->ldap()->dn();
    my $realm = $usersMod->kerberosRealm();
    my $ldapKerberosDN = "ou=Kerberos,$baseDn";
    my $ldapKerberosOU = new EBox::Users::OU(dn => $ldapKerberosDN);

    # If OpenLDAP doesn't have the Kerberos OU, we don't need to do anything.
    return unless ($ldapKerberosOU->exists());

    my $ldbKerberosOU = $sambaMod->ldbObjectFromLDAPObject($ldapKerberosOU);
    unless ($ldbKerberosOU) {
        my $parent = $sambaMod->ldbObjectFromLDAPObject($ldapKerberosOU->parent());
        if (not $parent) {
            throw EBox::Exceptions::External("Unable to to find the container for '$ldbKerberosOU' in Samba");
        }
        my $name = $ldapKerberosOU->name();
        my $parentDN = $parent->dn();
        EBox::debug("Loading OU $name into $parentDN");
        try {
            $ldbKerberosOU = EBox::Samba::OU->create(name => $name, parent => $parent);
        } otherwise {
            my $error = shift;
            throw EBox::Exceptions::Internal("Error loading OU '$name' in '$parentDN': $error");
        };
    }

    foreach my $module (@{$modules}) {
        my $principals = $module->kerberosServicePrincipals();
        my $samAccountName = "$principals->{service}-$hostname";
        try {
            my $smbUser = new EBox::Samba::User(samAccountName => $samAccountName);
            unless ($smbUser->exists()) {
                # Get the heimdal user to extract the kerberos keys. All service
                # principals for each module should have the same keys, so take
                # the first one.
                my $p = @{$principals->{principals}}[0];
                my $dn = "krb5PrincipalName=$p/$fqdn\@$realm,$ldapKerberosDN";
                my $user = new EBox::Users::User(dn => $dn, internal => 1);
                # If the user does not exists the module has not been enabled yet
                next unless ($user->exists());

                EBox::info("Importing service principal $dn");
                my %args = (
                    name           => scalar ($user->get('cn')),
                    parent         => $ldbKerberosOU,
                    samAccountName => scalar ($samAccountName),
                    description    => scalar ($user->get('description')),
                    kerberosKeys   => $user->kerberosKeys(),
                );
                $smbUser = EBox::Samba::User->create(%args);
                $smbUser->setCritical(1);
                $smbUser->setViewInAdvancedOnly(1);
            }
            foreach my $p (@{$principals->{principals}}) {
                try {
                    my $spn = "$p/$fqdn";
                    EBox::info("Adding SPN '$spn' to user " . $smbUser->dn());
                    $smbUser->addSpn($spn);
                } otherwise {
                    my $error = shift;
                    EBox::error("Error adding SPN '$p' to account '$samAccountName': $error");
                };
            }
        } otherwise {
            my $error = shift;
            EBox::error("Error adding account '$samAccountName': $error");
        };
    }
}

sub users
{
    my ($self) = @_;

    my $params = {
        base => $self->dn(),
        scope => 'sub',
        filter => '(&(&(objectclass=user)(!(objectclass=computer)))' .
                  '(!(showInAdvancedViewOnly=*))(!(isDeleted=*)))',
        attrs => ['*', 'unicodePwd', 'supplementalCredentials'],
    };
    my $result = $self->search($params);
    my $list = [];
    foreach my $entry ($result->sorted('samAccountName')) {
        my $user = new EBox::Samba::User(entry => $entry);
        push (@{$list}, $user);
    }
    return $list;
}

sub contacts
{
    my ($self) = @_;

    my $params = {
        base => $self->dn(),
        scope => 'sub',
        filter => '(&(&(objectclass=contact)(!(objectclass=computer)))' .
                  '(!(showInAdvancedViewOnly=*))(!(isDeleted=*)))',
        attrs => ['*'],
    };
    my $result = $self->search($params);
    my $list = [];
    foreach my $entry ($result->sorted('name')) {
        my $contact = new EBox::Samba::Contact(entry => $entry);

        push (@{$list}, $contact);
    }
    return $list;
}

sub groups
{
    my ($self) = @_;

    my $params = {
        base => $self->dn(),
        scope => 'sub',
        filter => '(&(objectclass=group)(!(showInAdvancedViewOnly=*))(!(isDeleted=*)))',
        attrs => ['*', 'unicodePwd', 'supplementalCredentials'],
    };
    my $result = $self->search($params);
    my $list = [];
    foreach my $entry ($result->sorted('samAccountName')) {

        next if (exists $self->{ignoredGroups}->{$entry->get_value('samAccountName')});

        my $group = new EBox::Samba::Group(entry => $entry);

        push (@{$list}, $group);
    }

    return $list;
}

sub ous
{
    my ($self) = @_;
    my $objectClass = EBox::Samba::OU->mainObjectClass();
    my %args = (
        base => $self->dn(),
        filter => "objectclass=$objectClass",
        scope => 'sub',
    );

    my $result = $self->ldap->search(\%args);

    my @ous = ();
    foreach my $entry ($result->entries)
    {
        my $ou = EBox::Samba::OU->new(entry => $entry);
        push (@ous, $ou);
    }

    return \@ous;
}

# Method: dnsZones
#
#   Returns the DNS zones stored in the samba LDB
#
sub dnsZones
{
    my ($self) = @_;

    my $defaultNC = $self->dn();
    my @zonePrefixes = (
        "CN=MicrosoftDNS,DC=DomainDnsZones,$defaultNC",
        "CN=MicrosoftDNS,DC=ForestDnsZones,$defaultNC",
        "CN=MicrosoftDNS,CN=System,$defaultNC");
    my @ignoreZones = ('RootDNSServers', '..TrustAnchors');
    my $zones = [];

    foreach my $prefix (@zonePrefixes) {
        my $params = {
            base => $prefix,
            scope => 'one',
            filter => '(objectClass=dnsZone)',
            attrs => ['*']
        };
        my $result = $self->search($params);
        foreach my $entry ($result->entries()) {
            my $name = $entry->get_value('name');
            next unless defined $name;
            next if $name eq any @ignoreZones;
            my $zone = new EBox::Samba::DNS::Zone(entry => $entry);
            push (@{$zones}, $zone);
        }
    }
    return $zones;
}

# Method: rootDse
#
#   Returns the root DSE
#
sub rootDse
{
    my ($self) = @_;

    return $self->ldbCon()->root_dse(attrs => ROOT_DSE_ATTRS);
}

1;
