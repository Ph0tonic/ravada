use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use IPC::Run3;
use Test::More;
use Test::SQL::Data;

use lib 't/lib';
use Test::Ravada;

my $test = Test::SQL::Data->new(config => 't/etc/sql.conf');

use_ok('Ravada');
my %ARG_CREATE_DOM = (
      KVM => [ id_iso => 1 ]
);

my @VMS = reverse keys %ARG_CREATE_DOM;
init($test->connector);
my $USER = create_user("foo","bar");

my $REMOTE_CONFIG;
##########################################################

sub test_node {
    my $vm_name = shift;

    die "Error: missing host in remote config\n ".Dumper($REMOTE_CONFIG)
        if !$REMOTE_CONFIG->{host};

    my $vm = rvd_back->search_vm($vm_name);

    my $node;
    eval { $node = $vm->new(%{$REMOTE_CONFIG}) };
    ok(!$@,"Expecting no error connecting to $vm_name at ".Dumper($REMOTE_CONFIG).", got :'"
        .($@ or '')."'");
    ok($node) or return;

    is($node->host,$REMOTE_CONFIG->{host});
    like($node->name ,qr($REMOTE_CONFIG->{host}));
    ok($node->vm,"[$vm_name] Expecting a VM in node");

    ok($node->id) or exit;

    my $node2 = Ravada::VM->open($node->id);
    is($node2->id, $node->id);
    is($node2->name, $node->name);
    return $node;
}

sub test_sync {
    my ($vm_name, $node, $clone) = @_;

    eval { $clone->rsync($node) };
    is($@,'') or return;
    # TODO test synced files

}

sub test_domain {
    my $vm_name = shift;
    my $node = shift;

    my $vm = rvd_back->search_vm($vm_name);

    my $base = create_domain($vm_name);
    is($base->_vm->host, 'localhost');

    $base->prepare_base(user_admin);

    my $clone = $base->clone(name => new_domain_name
        ,user => user_admin
    );

    test_sync($vm_name, $node, $clone);

    $clone->migrate($node);

    eval { $clone->start(user_admin) };
    ok(!$@,$node->name." Expecting no error, got ".($@ or ''));
    is($clone->is_active,1) or return;

    my $ip = $node->ip;
    like($clone->display(user_admin),qr($ip));

    if ($REMOTE_CONFIG->{public_ip}) {
        my $public_ip = $REMOTE_CONFIG->{public_ip};
        like($clone->display(user_admin),qr($public_ip));
        isnt($vm->host, $public_ip);
    } else {
        diag("SKIPPED: Add public_ip to remote_vm.conf to test nodes with 2 IPs");
    }
    return $clone;
}


sub test_domain_no_remote {
    my ($vm_name, $node) = @_;

    my $domain;
    eval {
        $domain = $node->create_domain(
            name => new_domain_name
            ,id_owner => user_admin->id
            ,id_iso => 1
        );
    };
    like($@,qr'.');

    $domain->remove(user_admin) if $domain;
}

sub test_remove_domain_from_local {
    my ($vm_name, $node, $domain_orig) = @_;

    warn "Removing domain ".$domain_orig->name." from local";
    my $vm = rvd_back->search_vm($vm_name);
    my $domain = $vm->search_domain($domain_orig->name);

    my @volumes = $domain->list_volumes();

    eval {$domain->remove(user_admin); };
    is($@,'');

    my $domain2 = $vm->search_domain($domain->name);
    ok(!$domain2,"Expecting no domain in local");

    my $domain3 = $node->search_domain($domain->name);
    ok(!$domain3,"Expecting no domain in node");

    test_remove_domain_node($node, $domain, \@volumes);

    test_remove_domain_node($vm, $domain, \@volumes);
}


sub test_remove_domain {
    my ($vm_name, $node, $domain) = @_;

    my @volumes = $domain->list_volumes();

    eval {$domain->remove(user_admin); };
    is($@,'');

    test_remove_domain_node($node, $domain, \@volumes);

    my $vm = rvd_back->search_vm($vm_name);
    isnt($vm->name, $node->name) or return;

    test_remove_domain_node($vm, $domain, \@volumes);
}

sub test_remove_domain_node {
    my ($node, $domain, $volumes) = @_;

    diag("checking removed volumes from ".$node->name);
    my %found = map { $_ => 0 } @$volumes;

    $node->_refresh_storage_pools();
    for my $pool ($node->vm->list_all_storage_pools()) {
        for my $vol ($pool->list_all_volumes()) {
            my $path = $vol->get_path();
            $found{$path}++ if exists $found{$path};
        }
    }
    for my $path (keys %found) {
        ok(!$found{$path},$node->name." Expecting vol $path removed")
            or exit;
    }

}
#############################################################

clean();

for my $vm_name ('KVM') {
my $vm;
eval { $vm = rvd_back->search_vm($vm_name) };

SKIP: {

    my $msg = "SKIPPED: $vm_name virtual manager not found ".($@ or '');
    $REMOTE_CONFIG = remote_config($vm_name);
    if (!keys %$REMOTE_CONFIG) {
        my $msg = "skipped, missing the remote configuration for $vm_name in the file "
            .$Test::Ravada::FILE_CONFIG_REMOTE;
        diag($msg);
        skip($msg,10);
    }

    if ($vm && $vm_name =~ /kvm/i && $>) {
        $msg = "SKIPPED: Test must run as root";
        $vm = undef;
    }

    diag($msg)      if !$vm;
    skip($msg,10)   if !$vm;

    my $node = test_node($vm_name)  or next;

    next if !$node || !$node->vm;

    test_domain_no_remote($vm_name, $node);

    my $domain2 = test_domain($vm_name, $node);
    test_remove_domain_from_local($vm_name, $node, $domain2)    if $domain2;

    my $domain3 = test_domain($vm_name, $node);
    test_remove_domain($vm_name, $node, $domain3)               if $domain3;


}

}

clean();

done_testing();