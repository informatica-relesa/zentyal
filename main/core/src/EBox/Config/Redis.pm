# Copyright (C) 2010-2012 eBox Technologies S.L.
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

package EBox::Config::Redis;

use 5.010001;
use strict;
use warnings;

use Redis;
use EBox::Config;
use EBox::Service;
use EBox::Module::Base;
use POSIX ':signal_h';
use YAML::XS;
use File::Slurp;
use File::Basename;
use Perl6::Junction qw(any);
use Error qw/:try/;

my $redis = undef;

# Constants
use constant REDIS_CONF => 'conf/redis.conf';
use constant REDIS_PASS => 'conf/redis.passwd';
use constant CLIENT_CONF => EBox::Config::etc() . 'core.conf';

use constant REDIS_TYPES => qw(string set list hash);

my %cache;
my @queue;

# Constructor: new
#
sub new
{
    my ($class, %args) = @_;

    my $self = {};
    bless($self, $class);

    # Launch daemon if it does not exists
    unless (defined $redis) {
        $self->_initRedis;
        $self->_respawn;
    }
    $self->{redis} = $redis;
    $self->{pid} = $$;

    return $self;
}

# Method: set_string
#
#   Set key to $value
#
sub set_string
{
    my ($self, $key, $value) = @_;

    my $tran = $self->begin();

    # Sets the new key
    $self->_redis_call('set', $key, $value);

    # Update parent dir info with the new key
    $self->_parent_add($key);

    $self->commit() if $tran;
}

# Method: get_string
#
#   Fetch the value stored in key
#
sub get_string
{
    my ($self, $key) = @_;

    return $self->_redis_call('get', $key);
}

# Method: set_int
#
#   Set $key to $value
#
sub set_int
{
    my ($self, $key, $value) = @_;

    $self->set_string($key, $value);
}

# Method: get_int
#
#   Fetch the value stored in $key
#
sub get_int
{
    my ($self, $key) = @_;

    return $self->get_string($key);
}

# Method:  set_bool
#
#   Set $key to $value
#
sub set_bool
{
    my ($self, $key, $value) = @_;

    $self->set_string($key, $value ? 1 : 0);
}

# Method: get_bool
#
#    Fetch the value stored in $key
#
sub get_bool
{
    my ($self, $key) = @_;

    return $self->get_string($key);
}

# Method: set_list
#
#   Set $key to $list. Where $list is an array ref.
#
sub set_list
{
    my ($self, $key, $list) = @_;

    my $tran = $self->begin();

    $self->_redis_call('del', $key);
    for my $value (@{$list}) {
        $self->_redis_call('rpush', $key, $value);
    }

    # Update parent dir info with the new key
    $self->_parent_add($key);

    $self->commit() if $tran;
}

# Method: get_list
#
#   Fetch the array ref stored in $key
#
sub get_list
{
    my ($self, $key) = @_;

    my @list = $self->_redis_call('lrange', $key, 0, -1);
    if (@list) {
        return \@list;
    } else {
        return [];
    }
}

# Method: set_hash
#
#   Set $key to $hash. Where $hash is an array ref.
#
sub set_hash
{
    my ($self, $key, $hash) = @_;

    # TODO: transaction here or is it not needed?

    $self->_redis_call('del', $key);
    $self->_redis_call('hmset', $key, %{$hash});

    # Update parent dir info with the new key
    $self->_parent_add($key);
}

# Method: get_hash
#
#   Fetch the hash ref stored in $key
#
sub get_hash
{
    my ($self, $key) = @_;

    unless ($self->exists($key)) {
        return {};
    }
    return {$self->_redis_call('hgetall', $key)};
}

# Method: set_set
#
#   Set $key to $set. Where $set is an array ref.
#
sub set_set
{
    my ($self, $key, $set) = @_;
    $self->_redis_call('del', $key);
    for my $value (@{$set}) {
        $self->_redis_call('sadd', $key, $value);
    }
}

# Method: get_set
#
#   Fetch the array ref stored in $key
#
sub get_set
{
    my ($self, $key) = @_;

    my @set = $self->_redis_call('smembers', $key);
    if (@set) {
        return \@set;
    } else {
        return [];
    }
}

# Method: get_set_size
#
#   Fetch the size of the set stored in $key
#
sub get_set_size
{
    my ($self, $key) = @_;

    return $self->_redis_call('scard', $key);
}

# Method: is_member
#
#   Check if $value is member of the $key set
#
sub is_member
{
    my ($self, $key, $value) = @_;

    return $self->_redis_call('sismember', $key, $value);
}

# Method: all_dirs
#
#   Return an array ref contaning all the directories in $key
#
sub all_dirs
{
    my ($self, $key) = @_;

    my @dirs = @{$self->get_set(_dir($key))};
    @dirs = map { "$key/$_" } @dirs;
    @dirs = grep { $self->get_set_size(_dir($_)) > 0 } @dirs;
    @dirs = sort @dirs;

    return \@dirs;
}

# Method: all_entries
#
#   Return an array ref contaning all the entries in $key
#
sub all_entries
{
    my ($self, $key, $includeDir) = @_;

    my @keys = @{$self->get_set(_dir($key))};
    @keys = map { "$key/$_" } @keys;

    if ($includeDir) {
        push (@keys, _dir($key));
    }
    @keys = sort @keys;

    return \@keys;
}

# Method: dir_exists
#
#   Returns true if the given directory exists in the loaded configuration.
#
sub dir_exists
{
    my ($self, $dir) = @_;

    return $self->exists(_dir($dir));
}

# Method: delete_dir
#
#   Delete a directory recursively
#
sub delete_dir
{
    my ($self, $dir) = @_;

    my $tran = $self->begin();

    if ($self->dir_exists($dir)) {
        my @keys = $self->_redis_call('keys', "$dir/*");
        $self->_redis_call('del', @keys);

        $self->_parent_del($dir);
    }

    $self->commit() if $tran;
}

# Method: unset
#
#   Unset a key
#
sub unset
{
    my ($self, $key) = @_;

    my $tran = $self->begin();

    $self->_redis_call('del', $key);

    # Delete reference to the key in parent
    $self->_parent_del($key);

    $self->commit() if $tran;
}

# Method: exists
#
#   Check if a given key exists
#
sub exists
{
    my ($self, $key) = @_;

    $self->_redis_call('exists', $key);
}

# Method: get
#
# Generic get to retrieve keys. It will
# automatically check if it's a scalar,
# list, set or hash value unless optional
# type argument is specified.
#
sub get
{
    my ($self, $key, $type) = @_;

    unless (defined ($type)) {
        $type = $self->_redis_call('type', $key);
    }

    if ($type eq any((REDIS_TYPES))) {
        my $getter = "get_$type";
        return $self->$getter($key);
    } else {
        return undef;
    }
}

# Method: set
#
# Generic method to key values. It will
# automatically check if it's a scalar,
# list or hash value unless the optional
# type argument is specified.
#
sub set
{
    my ($self, $key, $value, $type) = @_;

    unless (defined ($type)) {
        $type = ref ($value);
        if ($type eq 'ARRAY') {
            if ($key eq _dir($key)) {
                $type = 'set';
            } else {
                $type = 'list';
            }
        } elsif ($type eq 'HASH') {
            $type = 'hash';
        } else {
            $type = 'string';
        }
    }

    if ($type eq any((REDIS_TYPES))) {
        my $setter = "set_$type";
        return $self->$setter($key, $value);
    } else {
        return undef;
    }
}

# Method: backup_dir
#
#   Back up a given dir $key in $dest
#
sub backup_dir
{
    my ($self, $key, $dest) = @_;

    $self->delete_dir($dest);
    $self->_backup_dir(
        key => $key,
        destination_type => 'redis',
        destination => $dest
    );
}

# Method: restore_dir
#
#   Restore orig/$key in $dest
#
sub restore_dir
{
    my ($self, $key, $orig, $dest) = @_;

    $self->delete_dir($dest . $key);
    $self->_restore_dir($key, $orig, $dest);
}


# Method: export_dir_to_yaml
#
#   Back up a given dir in YAML file
#
# Parameters:
#
#   key         - key for the directory
#   file        - yaml file to write
#   includeDirs - *optional* include directory sets in the dump (default: no)
#
sub export_dir_to_yaml
{
    my ($self, $key, $file, $includeDirs) = @_;

    my @keys;
    $self->_backup_dir(
        key => $key,
        destination_type => 'yaml',
        destination => \@keys,
        include_dirs => $includeDirs
    );
    try {
        YAML::XS::DumpFile($file, @keys);
    } otherwise {
        throw EBox::Exceptions::External("Error dumping $key to YAML:$file");
    };
}

sub set_hash_value
{
    my ($self, $key, $field, $value) = @_;

    $self->_redis_call('hset', $key, $field, $value);

    # Update parent dir info with the new key
    $self->_parent_add($key);
}

sub hash_field_exists
{
    my ($self, $key, $field) = @_;

    return $self->_redis_call('hexists', $key, $field);
}

sub hash_value
{
    my ($self, $key, $field) = @_;

    return $self->_redis_call('hget', $key, $field);
}

sub hash_delete
{
    my ($self, $key, $field) = @_;

    $self->_redis_call('hdel', $key, $field);

    # Delete reference to the key in parent
    $self->_parent_del($key);
}

# Method: import_dir_from_yaml
#
#   Given a YAML file, restore all its keys/values under destination folder
#
# Parameters:
#
#   filename - YAML filename
#   dest - destination folder key
#
sub import_dir_from_yaml
{
    my ($self, $filename, $dest) = @_;

    my @keys;

    try {
        @keys = YAML::XS::LoadFile($filename);
    } otherwise {
        throw EBox::Exceptions::External("Error parsing YAML:$filename");
    };

    for my $entry (@keys) {
        my $value = $entry->{value};
        my $key;
        if ($dest) {
            $key = $dest . $entry->{key};
        } else {
            $key = $entry->{key};
        }
        my $type = $entry->{type};
        $self->set($key, $value, $type);
    }
}

# Get the set associated to a directory key
sub _dir
{
    my ($key) = @_;

    # Return the same if already a dir
    if (substr ($key, -2, 2) eq '/.') {
        return $key;
    }

    # Do not add redundant slashes
    if (substr ($key, -1, 1) eq '/') {
        return $key . '.';
    } else {
        return "$key/.";
    }
}

# Update directory tree with a new entry
sub _parent_add
{
    my ($self, $key) = @_;

    my $parentkey = dirname($key);
    my $subkey = basename($key);
    my $parentdir = _dir($parentkey);

    # Stop recursion if already member
    if ($self->is_member($parentdir, $subkey)) {
        return;
    }

    $self->_redis_call('sadd', $parentdir, $subkey);

    # Recursive propagation until the root
    unless ($parentkey eq '/') {
        $self->_parent_add($parentkey);
    }
}

# Delete entry reference in parent directory
sub _parent_del
{
    my ($self, $key) = @_;

    my $parent = dirname($key);
    my $subkey = basename($key);
    $self->_redis_call('srem', _dir($parent), $subkey);
}

sub _backup_dir
{
    my ($self, %args) = @_;

    my $key = $args{key};
    my $destinationType = $args{destination_type};
    my $dest = $args{destination};
    my $includeDirs = $args{include_dirs};

    for my $entry (@{$self->all_entries($key, $includeDirs)}) {
        my $type = $self->_redis_call('type', $entry);
        my $destKey = $entry;
        if ($destinationType eq 'redis') {
            $destKey = $dest . substr($destKey, length($key));
        }

        my $value = $self->get($entry, $type);
        if ($destinationType eq 'redis') {
            $self->set($destKey, $value, $type);
        } else {
            if ($type eq any((REDIS_TYPES))) {
                push (@{$args{destination}},
                        {
                            type => $type,
                            key => $destKey,
                            value => $value
                        }
                     );
            }
        }
    }

    my $destKey = $dest;
    for my $subdir (@{$self->all_dirs($key)}) {
        if ($destinationType eq 'redis') {
            $destKey = $dest . substr($subdir, length($key));
        }
        $self->_backup_dir(
            key => $subdir,
            destination => $destKey,
            destination_type => $destinationType,
            include_dirs => $includeDirs
        );
    }
}

sub _restore_dir
{
    my ($self, $key, $orig, $dest) = @_;

    for my $entry (@{$self->all_entries($orig . $key)}) {
        my $type = $self->_redis_call('type', $entry);
        my $destKey = $dest . substr($entry, length($orig));
        my $value = $self->get($entry, $type);
        $self->set($destKey, $value, $type);
    }
    for my $subdir (@{$self->all_dirs($orig. $key)}) {
        $self->_restore_dir(substr($subdir, length($orig)), $orig, $dest);
    }
}

sub begin
{
    my ($self) = @_;

    # Do not allow nested transactions
    if ($self->{tran}) {
        return 0;
    }

    # TODO: flush queue also here?
    $self->{tran} = 1;

    # TODO: empty cache if other process has modified it
    #%cache = ();

    return 1;
}

sub commit
{
    my ($self) = @_;

    $self->_flush_queue();

    $self->{tran} = 0;
}

sub rollback
{
    my ($self) = @_;

    if ($self->{multi}) {
        $self->_redis_call_wrapper(0, 'discard');
    }

    $self->{tran} = 0;
}

sub _flush_queue
{
    my ($self) = @_;

    $self->{multi} = (@queue > 1);

    if ($self->{multi}) {
        $self->_redis_call_wrapper(0, 'multi');
    }

    while (@queue) {
        my $cmd = shift (@queue);
        $self->_redis_call_wrapper(0, $cmd->{cmd}, @{$cmd->{args}});
    }

    if ($self->{multi}) {
        $self->_redis_call_wrapper(1, 'exec');
    }
}

# Redis call proxy, tries to get the result from cache and fallbacks
# to _redis_call_wrapper if not present or cache dirty
#
sub _redis_call
{
    my ($self, $command, @args) = @_;

    # Check process id and respawn redis if has changed (fork)
    if ($self->{pid} ne $$) {
        $self->_respawn();
    }

    my $wantarray = wantarray;
    my ($key, @values) = @args;
    my $value = $values[0];

    # FIXME: Warning, this cache stuff is completely broken
    # if there are more than one process

    my $write = 1;
    if ($command eq 'set') {
        $cache{$key} = { type => 'string', value => $value };
    } elsif ($command eq 'del') {
        delete $cache{$key};
    } elsif (($command eq 'hset') or ($command eq 'hmset')) {
        unless (exists $cache{$key} and exists $cache{$key}->{value}) {
            $cache{$key} = { type => 'hash', value => {} };
        }
        my $field;
        while (@values) {
            $field = shift @values;
            $value = shift @values;
            $cache{$key}->{value}->{$field} = $value;
        }
    } elsif (($command eq 'hdel') or ($command eq 'srem')) {
        foreach my $field (@values) {
            delete $cache{$key}->{value}->{$field};
        }
    } elsif ($command eq 'rpush') {
        unless (exists $cache{$key} and exists $cache{$key}->{value}) {
            $cache{$key} = { type => 'list', value => [] };
        }
        foreach my $val (@values) {
            push (@{$cache{$key}->{value}}, $val);
        }
    } elsif ($command eq 'sadd') {
        unless (exists $cache{$key} and exists $cache{$key}->{value}) {
            $cache{$key} = { type => 'set', value => {} };
        }
        foreach my $val (@values) {
            $cache{$key}->{value}->{$val} = 1;
        }
    } else {
        $write = 0;

        if ($command eq 'keys') {
            my $keys = $self->_redis_call_wrapper(1, 'keys', $key);

            foreach my $name (@{$keys}) {
                unless (exists $cache{$name}) {
                    $cache{$name} = {};
                }
            }

            chop ($key); # remove the '*' at the end
            my @keylist;
            foreach my $name (keys %cache) {
                if ($name =~ /^$key/) {
                    push (@keylist, $name);
                }
            }
            return @keylist;
        }

        # Get from redis if not in cache
        if (($command eq 'exists') and not exists $cache{$key}) {
            if ($self->_redis_call_wrapper(0, 'exists', $key)) {
                $cache{$key} = {};
            }
        } elsif (($command eq 'type') and not exists $cache{$key}->{type}) {
            $value = $self->_redis_call_wrapper(0, 'type', @args);
            $cache{$key} = { type => $value };
        } elsif (not exists $cache{$key}->{value}) {
            if (($command eq 'smembers') or
                ($command eq 'scard') or ($command eq 'sismember')) {
                $value = $self->_redis_call_wrapper(1, 'smembers', $key);
                my %members = map { $_ => 1 } @{$value};
                $cache{$key} = { type => 'set', value => \%members };
            } elsif (($command eq 'hget') or ($command eq 'hgetall')) {
                $value = $self->_redis_call_wrapper(1, 'hgetall', $key);
                $cache{$key} = { type => 'hash', value => {@{$value}} };
            } else {
                $value = $self->_redis_call_wrapper($wantarray, $command, @args);
                if ($command eq 'get') {
                    $cache{$key} = { type => 'string', value => $value };
                } elsif ($command eq 'lrange') {
                    $cache{$key} = { type => 'list', value => $value };
                }
            }
        }

        # Get value from cache
        if ($command eq 'exists') {
            return exists $cache{$key};
        } elsif ($command eq 'get') {
            return $cache{$key}->{value};
        } elsif ($command eq 'sismember') {
            return $cache{$key}->{value}->{$value};
        } elsif ($command eq 'lrange') {
            return () unless (defined $cache{$key}->{value});
            return @{$cache{$key}->{value}};
        } elsif ($command eq 'smembers') {
            return keys %{$cache{$key}->{value}};
        } elsif ($command eq 'scard') {
            return scalar (keys %{$cache{$key}->{value}});
        } elsif ($command eq 'hget') {
            return undef unless (exists $cache{$key}->{value}->{$value});
            return $cache{$key}->{value}->{$value};
        } elsif ($command eq 'hgetall') {
            return () unless (defined $cache{$key}->{value});
            return %{$cache{$key}->{value}};
        } elsif ($command eq 'type') {
            return $cache{$key}->{type};
        }
    }

    if ($write) {
        push (@queue, { cmd => $command, args => \@args });
    }
}

# Wrapper to reconnect to redis in case of detecting a failure when
# issuing a command.
#
sub _redis_call_wrapper
{
    my ($self, $wantarray, $command, @args) = @_;

    my $response;
    my @response;

    my $tries = 5;
    for my $i (1 .. $tries) {
        our $failure = 1;
        our $ret;
        {
            local $SIG{PIPE};
            $SIG{PIPE} = sub {
                # EBox::warn("$$ Reconnecting to redis server after SIGPIPE");
                $failure = 1; };
            eval {
                $self->{redis}->__send_command($command, @args);
                if ($wantarray) {
                    @response = $self->{redis}->__read_response();
                    map { utf8::encode($_) if defined ($_) } @response;
                    $response = \@response;
                } else {
                    $response = $self->{redis}->__read_response();
                    utf8::encode($response) if defined ($response);
                }
                $failure = 0;
            };
            $ret = $@;
            if ($ret or $failure) {
                # EBox::warn("$$ - $ret");
                sleep(1);
                # Disconnected, try to reconnect
                eval {
                    $self->_initRedis();
                    $self->_respawn();
                    $failure = 1;
                };
                if ($@) {
                    # EBox::warn("$$ -- $@");
                    sleep(1);
                    $failure = 1;
                }
            }
        }

        if ($failure) {
            if ( $i < $tries) {
                warn "Reconnecting to redis server ($i try)...";
            } else {
                my $conProblem = 1;
                if ($ret) {
                    $conProblem = $ret =~ m/closed connection/;
                }

                if ($conProblem) {
                    throw EBox::Exceptions::Internal('Cannot connect to redis server');
                } else {
                    my $error = "Redis command '$command @args' failed: $ret";
                    throw EBox::Exceptions::Internal($error);
                }
            }
        } else {
            return $response;
        }
    }
}

# Reconnect to redis server
sub _respawn
{
    my ($self) = @_;

    # try {
    #     $self->{redis}->quit();
    # } otherwise { ; };
    $self->{redis} = undef;
    $redis = undef;

    my $user = $self->_user();
    my $filepasswd = $self->_passwd();

    $redis = Redis->new(sock => "/var/lib/zentyal/redis.$user.sock");
    $redis->auth($filepasswd);
    $self->{redis} = $redis;
    $self->{pid} = $$;

    # EBox::info("$$ Respawning the redis connection");
}


# Initialize redis daemon if it's not running
sub _initRedis
{
    my ($self) = @_;

    # User corner redis server is managed by service
    return if ( $self->_user eq 'ebox-usercorner' );

    unless (EBox::Service::running('ebox.redis')) {
        EBox::info('Starting redis server');

        # Write redis daemon conf file
        $self->writeConfigFile();

        # Launch daemon, added sleep to avoid first connection problems
        EBox::Sudo::silentRoot('start ebox.redis && sleep 1');
    }
}


# Method: writeConfigFile
#
#   Write redis daemon config file
#
sub writeConfigFile
{
    my ($self, $user) = @_;

    defined($user) or $user = EBox::Config::user();

    my $home = $self->_home($user);

    my $confFile = $home . REDIS_CONF;
    my $pass = $self->_passwd($home);
    my $uid = getpwnam($user);
    my $dir = $user;
    $dir =~ s/ebox/zentyal/;
    my $port = $self->_port($user);

    my @params = ();
    push (@params, user => $user);
    push (@params, dir => $dir);
    push (@params, port => $port);
    push (@params, passwd => $pass);
    EBox::Module::Base::writeConfFileNoCheck($confFile,
            'core/redis.conf.mas',
            \@params, {mode => '0600', uid => $uid});
}

# Stop redis server, sync changes to disk before
sub stopRedis
{
    my ($self) = @_;

    # User corner redis server is managed by service
    return if ($self->_user eq 'ebox-usercorner');

    $self->_redis_call_wrapper(0, 'save');
    EBox::Service::manage('ebox.redis', 'stop');
}


# Returns redis server password
sub _passwd
{
    my ($self, $home) = @_;
    defined($home) or $home = $self->_home();

    return read_file($home . REDIS_PASS) or
        throw EBox::Exceptions::External('Could not open passwd file');
}


# Returns redis server port
sub _port
{
    my ($self, $user) = @_;
    defined($user) or $user = $self->_user();

    if ($user eq 'ebox-usercorner') {
        return EBox::Config::configkey('redis_port_usercorner');
    } else {
        return EBox::Config::configkeyFromFile('redis_port', CLIENT_CONF);
    }

    # Unknown user
    return undef;
}


sub _home
{
    my ($self, $user) = @_;
    defined($user) or $user = $self->_user();

    my ($name,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire) = getpwnam($user);
    return $dir;
}


# Returns current user name
sub _user
{
    my @userdata = getpwuid(POSIX::getuid());
    return $userdata[0];
}

1;
