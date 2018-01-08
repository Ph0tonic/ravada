use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use IPC::Run 'run';
use Test::More;
use Test::SQL::Data;

use lib 't/lib';
use Test::Ravada;

no warnings "experimental::signatures";
use feature qw(signatures);

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

sub test_node_renamed {
    my $vm_name = shift;
    my $node = shift;

    my $name = $node->name;

    my $name2 = "knope_".new_domain_name();

    my $sth= $test->connector->dbh->prepare(
        "UPDATE vms SET name=? WHERE name=?"
    );
    $sth->execute($name2, $name);
    $sth->finish;

    my $node2 = Ravada::VM->open($node->id);
    ok($node2,"Expecting a node id=".$node->id) or return;
    is($node2->name, $name2)                    or return;
    is($node2->id, $node->id)                   or return;

    my $rvd_back2 = Ravada->new(
        connector => $test->connector
        ,config => "t/etc/ravada.conf"
    );
    is(scalar(@{rvd_back->vm}), scalar(@{$rvd_back2->vm}),Dumper(rvd_back->vm)) or return;
    my $list_nodes2 = rvd_front->list_nodes;

    my ($node_f) = grep { $_->{name} eq $name2} @$list_nodes2;
    ok($node_f,"[$vm_name] expecting node $name2 in frontend ".Dumper($list_nodes2));

    $sth->execute($name,$name2);
    $sth->finish;

    $list_nodes2 = rvd_front->list_nodes;
    ($node_f) = grep { $_->{name} eq $name} @$list_nodes2;
    ok($node_f,"[$vm_name] expecting node $name in frontend ".Dumper($list_nodes2));

}

sub test_node {
    my $vm_name = shift;

    die "Error: missing host in remote config\n ".Dumper($REMOTE_CONFIG)
        if !$REMOTE_CONFIG->{host};

    my $vm = rvd_back->search_vm($vm_name);

    my $list_nodes = rvd_front->list_nodes;

    my $node;
    diag("Testing $vm_name $REMOTE_CONFIG->{name}");
    eval { $node = $vm->new(%{$REMOTE_CONFIG}) };
    ok(!$@,"Expecting no error connecting to $vm_name at ".Dumper($REMOTE_CONFIG).", got :'"
        .($@ or '')."'") or return;
    ok($node) or return;

    is($node->type,$vm->type) or return;

    is($node->host,$REMOTE_CONFIG->{host});

    _start_node($node);

    clean_remote_node($node);

    { $node->vm };
    is($@,'')   or return;

    ok($node->id) or return;
    is($node->is_active,1) or return;

    ok(!$node->is_local,"[$vm_name] node remote");

    my $node2 = Ravada::VM->open($node->id);
    is($node2->id, $node->id);
    is($node2->name, $node->name);
    is($node2->public_ip, $node->public_ip);
    ok(!$node2->is_local,"[$vm_name] node remote") or return;

    my @nodes = $vm->list_nodes();
    is(scalar @nodes, 2,"[$vm_name] Expecting nodes") or return;

    my $list_nodes2 = rvd_front->list_nodes;
    is(scalar @$list_nodes2, (scalar @$list_nodes)+1,Dumper($list_nodes,$list_nodes2)) or return;
    return $node;
}

sub test_sync {
    my ($vm_name, $node, $base, $clone) = @_;

    eval { $clone->rsync($node) };
    is(''.$@,'') or return;
    # TODO test synced files

    eval { $base->rsync($node) };
    is($@,'') or return;

    eval { $clone->rsync($node) };
    is($@,'') or return;
}

sub test_domain {
    my $vm_name = shift;
    my $node = shift or die "Missing node";

    my $vm = rvd_back->search_vm($vm_name);

    my $base = create_domain($vm_name);
    is($base->_vm->host, 'localhost');

    $base->prepare_base(user_admin);
    $base->rsync($node);
    my $clone = $base->clone(name => new_domain_name
        ,user => user_admin
    );

    test_sync($vm_name, $node, $base, $clone);

    eval { $clone->migrate($node) };
    is(''.$@ , '') or return;

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
    like($@,qr'.',"Expecting no domain in remote node by now");

    $domain->remove(user_admin) if $domain;
}

sub test_remove_domain_from_local {
    my ($vm_name, $node, $domain_orig) = @_;
    $domain_orig->shutdown_now(user_admin)   if $domain_orig->is_active;

    my $vm = rvd_back->search_vm($vm_name);
    my $domain = $vm->search_domain($domain_orig->name);

    my @volumes = $domain->list_volumes();

    eval {$domain->remove(user_admin); };
    is(''.$@,'',"Expecting no errors removing domain ".$domain_orig->name);

    my $domain2 = $vm->search_domain($domain->name);
    ok(!$domain2,"Expecting no domain in local");

    my $domain3 = $node->search_domain($domain->name);
    ok(!$domain3,"Expecting no domain ".$domain->name." in node ".$node->name) or return;

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

    if ($node->type ne 'KVM') {
        diag("SKIPPING: test_remove_domain_node skipped on ".$node->type);
        return;
    }
    diag("[".$node->type."] checking removed volumes from ".$node->name);
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
            or return;
    }

}

sub test_domain_starts_in_same_vm {
    my ($vm_name, $node) = @_;

    my $domain = test_domain($vm_name, $node);

    my $display = $domain->display(user_admin);
    $domain->shutdown_now(user_admin)   if $domain->is_active;

    unlike($domain->_vm->host, qr/localhost/)   or return;
    is($domain->_vm->host, $node->host)         or return;

    my $domain2 = rvd_back->search_domain($domain->name);
    ok($domain2,"Expecting a domain called ".$domain->name) or return;

    $domain2->start(user => user_admin);
    is($domain2->_vm->host, $node->host);
    is($domain2->display(user_admin), $display);

    $domain->remove(user_admin);
}

sub test_sync_base {
    my ($vm_name, $node) = @_;

    my $vm =rvd_back->search_vm($vm_name);
    my $base = create_domain($vm_name);
    my $clone = $base->clone(
        name => new_domain_name
       ,user => user_admin
    );

    eval { $clone->migrate($node); };
    like($@, qr'.');

    eval { $base->rsync($node); };
    is(''.$@,'');

    is($base->base_in_vm($node->id),1,"Expecting domain ".$base->id
        ." base in node ".$node->id ) or return;

    eval { $clone->migrate($node); };
    is(''.$@,'');

    is($clone->_vm->host, $node->host);
    $clone->shutdown_now(user_admin);

    my $clone2 = $vm->search_domain($clone->name);
    is($clone2->_vm->host, $vm->host);

    eval { $clone2->migrate($node); };
    is(''.$@,'');

    is($clone2->_data('id_vm'),$node->id);

    my $clone3 = $node->search_domain($clone2->name);
    ok($clone3,"[$vm_name] expecting ".$clone2->name." found in "
                .$node->host) or return;

    my $domains = rvd_front->list_domains();
    my ($clone_f) = grep { $_->{name} eq $clone2->name } @$domains;
    ok($clone_f);
    is($clone_f->{id}, $clone2->id);
    is($clone_f->{node}, $clone2->_vm->host);
    is($clone_f->{id_vm}, $node->id);

    $clone->remove(user_admin);
    $base->remove(user_admin);

}

sub test_start_twice {
    my ($vm_name, $node) = @_;

    if ($vm_name ne 'KVM') {
        diag("SKIPPED: start_twice not available on $vm_name");
        return;
    }

    my $vm =rvd_back->search_vm($vm_name);
    my $base = create_domain($vm_name);
    my $clone = $base->clone(
        name => new_domain_name
       ,user => user_admin
    );
    $clone->shutdown_now(user_admin)    if $clone->is_active;
    is($clone->is_active,0);

    eval { $base->set_base_vm(vm => $node, user => user_admin); };
    is(''.$@,'') or return;

    eval { $clone->migrate($node); };
    is(''.$@,'')    or return;

    is($clone->_vm->host, $node->host);
    is($clone->is_active,0);

    my $clone2 = $vm->search_domain($clone->name);
    is($clone2->_vm->host, $vm->host);
    is($clone2->is_active,0);

    if ($vm_name eq 'KVM') {
        $clone2->domain->create();
    } elsif ($vm_name eq 'Void') {
        $clone2->_store(is_active => 1);
    } else {
        die "test_start_twice not available on $vm_name";
    }

    eval { $clone->start(user => user_admin ) };
    like(''.$@,qr'libvirt error code: 55,') if $vm_name eq 'KVM';
    is($clone->_vm->host, $vm->host,"[$vm_name] Expecting ".$clone->name." in ".$vm->ip)
        or return;
    is($clone->display(user_admin), $clone2->display(user_admin));

    $clone->remove(user_admin);
    $base->remove(user_admin);

}

sub test_rsync_newer {
    my ($vm_name, $node) = @_;

    if ($vm_name ne 'KVM') {
        diag("Skipping: Volumes not implemented for $vm_name");
        return;
    }
    my $domain = test_domain($vm_name, $node) or return;
    $domain->shutdown_now(user_admin)   if $domain->is_active;

    my ($volume) = $domain->list_volumes();
    my ($vol_name) = $volume =~ m{.*/(.*)};

    my $vm = rvd_back->search_vm($vm_name);

    my $capacity;
    { # vols equal, then resize
    my $vol = $vm->search_volume($vol_name);
    ok($vol,"[$vm_name] expecting volume $vol_name")    or return;
    ok($vol->get_info,"[$vm_name] No info for remote vol "
        .Dumper($vol)) or return;

    my $vol_remote = $node->search_volume($vol_name);
    ok($vol_remote->get_info,"[$vm_name] No info for remote vol "
        .Dumper($vol_remote)) or return;
    is($vol_remote->get_info->{capacity}, $vol->get_info->{capacity});

    $capacity = int ($vol->get_info->{capacity} *1.5 );
    $vol->resize($capacity);
    }

    { # vols different
    my $vol2 = $vm->search_volume($vol_name);
    my $vol2_remote = $node->search_volume($vol_name);

    is($vol2->get_info->{capacity}, $capacity);
    isnt($vol2_remote->get_info->{capacity}, $capacity);
    isnt($vol2_remote->get_info->{capacity}, $vol2->get_info->{capacity});
    }

    # on starting it should sync
    is($domain->_vm->host, $node->host);
    $domain->start(user => user_admin);
    is($domain->_vm->host, $node->host);

    { # syncs for start, so vols should be equal
    my $vol3 = $vm->search_volume($vol_name);
    my $vol3_remote = $node->search_volume($vol_name);
    is($vol3_remote->get_info->{capacity}, $vol3->get_info->{capacity});
    }


}

sub test_bases_node {
    my ($vm_name, $node) = @_;

    my $vm = rvd_back->search_vm($vm_name);

    my $domain = create_domain($vm_name);

    eval { $domain->base_in_vm($domain->_vm->id)};
    like($@,qr'is not a base');

#    is($domain->base_in_vm($domain->_vm->id),1);
    eval { $domain->base_in_vm($node->id) };
    like($@,qr'is not a base');

    $domain->prepare_base(user_admin);
    is($domain->base_in_vm($domain->_vm->id), 1);
    is($domain->base_in_vm($node->id), undef);

    $domain->migrate($node);
    is($domain->base_in_vm($node->id), 1);

    $domain->set_base_vm(vm => $node, value => 0, user => user_admin);
    is($domain->base_in_vm($node->id), 0);

    $domain->set_base_vm(vm => $vm, value => 0, user => user_admin);
    is($domain->is_base(),0);
    eval { is($domain->base_in_vm($vm->id), 0) };
    like($@,qr'is not a base');
    eval { is($domain->base_in_vm($node->id), 0) };
    like($@,qr'is not a base');

    my $req = Ravada::Request->set_base_vm(
                uid => user_admin->id
             ,id_vm => $vm->id
         ,id_domain => $domain->id
    );
    rvd_back->_process_all_requests_dont_fork();
    is($req->status,'done') or die Dumper($req);
    is($req->error,'');
    is($domain->base_in_vm($vm->id), 1);

    $req = Ravada::Request->remove_base_vm(
                uid => user_admin->id
             ,id_vm => $vm->id
         ,id_domain => $domain->id
    );
    rvd_back->_process_all_requests_dont_fork();
    eval { $domain->base_in_vm($vm->id)};
    like($@,qr'is not a base');

    $domain->remove(user_admin);
}

sub test_clone_not_in_node {
    my ($vm_name, $node) = @_;

    my $vm = rvd_back->search_vm($vm_name);

    my $domain = create_domain($vm_name);

    $domain->prepare_base(user_admin);
    $domain->set_base_vm(vm => $node, user => user_admin);

    is($domain->base_in_vm($node->id), 1);

    my @clones;
    warn "starting 4 clones\n";
    for ( 1 .. 4 ) {
        my $clone1 = $domain->clone(name => new_domain_name, user => user_admin);
        push @clones,($clone1);
        is($clone1->_vm->host, 'localhost');
        eval { $clone1->start(user_admin) };
        is(''.$@,'',"[$vm_name] Clone of ".$domain->name." failed ".$clone1->name) or return;
        is($clone1->is_active,1);

    # search the domain in the underlying VM
        if ($vm_name eq 'KVM') {
            my $virt_domain;
            eval { $virt_domain = $clone1->_vm->vm
                                ->get_domain_by_name($clone1->name) };
            is(''.$@,'');
            ok($virt_domain,"Expecting ".$clone1->name." in "
                .$clone1->_vm->host);
        }
        warn "started on ".$clone1->_vm->host;
        last if $clone1->_vm->host ne $clones[0]->_vm->host;
    }


    isnt($clones[-1]->_vm->host, $clones[0]->_vm->host,"[$vm_name] "
        .$clones[-1]->name
        ." - ".$clones[0]->name) or return;
    for (@clones) {
        $_->remove(user_admin);
    }
    $domain->remove(user_admin);
}

sub test_domain_already_started {
    my ($vm_name, $node) = @_;

    my $vm = rvd_back->search_vm($vm_name);

    my $domain = create_domain($vm_name);

    $domain->prepare_base(user_admin);
    $domain->set_base_vm(vm => $node, user => user_admin);

    is($domain->base_in_vm($node->id), 1);

    my $clone = $domain->clone(name => new_domain_name, user => user_admin);
    is($clone->_vm->host, 'localhost');

    eval { $clone->migrate($node) };
    is(''.$@,'')                        or return;
    is($clone->_vm->host, $node->host);
    is($clone->_vm->id, $node->id) or return;

    is($clone->_data('id_vm'), $node->id) or return;

    {
        my $clone_copy = $node->search_domain($clone->name);
        ok($clone_copy,"[$vm_name] expecting domain ".$clone->name
                        ." in node ".$node->host
        ) or return;
    }

    eval { $clone->start(user_admin) };
    is(''.$@,'',$clone->name) or return;
    is($clone->is_active,1);
    is($clone->_vm->id, $node->id)  or return;
    is($clone->_vm->host, $node->host)  or return;

    {
    my $clone2 = rvd_back->search_domain($clone->name);
    is($clone2->id, $clone->id);
    is($clone2->_vm->host , $clone->_vm->host);
    }

    my $sth = $test->connector->dbh->prepare("UPDATE domains set id_vm=NULL WHERE id=?");
    $sth->execute($clone->id);
    $sth->finish;

    { # clone is active, it should be found in node
    my $clone3 = rvd_back->search_domain($clone->name);
    is($clone3->id, $clone->id);
    is($clone3->_vm->host , $node->host) or return;
    }

    $clone->remove(user_admin);
    $domain->remove(user_admin);
}

sub test_prepare_sets_vm {
    my $vm_name = shift;
    my $vm = rvd_back->search_vm($vm_name);

    my $domain = create_domain($vm_name);
    eval { $domain->base_in_vm($vm->id) };
    like($@,qr'is not a base');

    $domain->prepare_base(user_admin);
    is($domain->base_in_vm($vm->id),1);

    $domain->remove_base(user_admin);
    eval { $domain->base_in_vm($vm->id) };
    like($@,qr'is not a base');

    $domain->remove(user_admin);
}

sub test_node_inactive {
    my ($vm_name, $node) = @_;

    _shutdown_node($node);
    is($node->is_active,0);

    my $list_nodes = rvd_front->list_nodes;
    my ($node2) = grep { $_->{name} eq $node->name} @$list_nodes;

    ok($node2,"[$vm_name] Expecting node called ".$node->name." in frontend")
        or return;
    is($node2->{is_active},0,Dumper($node2)) or return;

    _start_node($node);

    for ( 1 .. 10 ) {
        last if $node->is_active;
        sleep 1;
        diag("[$vm_name] waiting for node ".$node->name);
    }
    is($node->is_active,1,"[$vm_name] node ".$node->name." active");

}

sub _shutdown_node($node) {

    for my $domain ($node->list_domains(active => 1)) {
        diag("Shutting down ".$domain->name." on node ".$node->name);
        $domain->shutdown_now(user_admin);
    }
    $node->disconnect;

    my $domain_node = _domain_node($node);
    eval {
        $domain_node->shutdown(user => user_admin);# if !$domain_node->is_active;
    };
    sleep 2 if !$node->ping;
    for ( 1 .. 10 ) {
        diag("Waiting for node ".$node->name." to be inactive $_");
        last if !$node->ping;
        sleep 1;
    }
    is($node->ping,0);
}

sub _domain_node($node) {
    my $vm = rvd_back->search_vm('KVM','localhost');
    my $domain = $vm->search_domain($node->name);
    $domain = rvd_back->import_domain(name => $node->name
            ,user => user_admin->name
            ,vm => 'KVM'
            ,spinoff_disks => 0
    )   if !$domain || !$domain->is_known;

    ok($domain->id,"Expecting an ID for domain ".Dumper($domain)) or exit;
    $domain->_set_vm($vm, 'force');
    return $domain;
}
sub _start_node($node) {

    confess "Undefined node " if!$node;

    $node->disconnect;
    if ( $node->is_active ) {
        warn "Node ".$node->name." active\n";
        $node->connect && return;
        warn "I can't connect";
    }

    my $domain = _domain_node($node);
    diag("Starting domain/node ".$domain->name);

    ok($domain->_vm->host eq 'localhost');

    $domain->start(user_admin);

    sleep 2;

    $node->disconnect;
    sleep 1;

    for ( 1 .. 10 ) {
        last if $node->is_active;
        sleep 1;
        diag("Waiting for node ".$node->name." $_");
    }
    is($node->ping,1,"Expecting active node ".$node->name." can be pinged");
    $node->connect;
}

sub remove_node($node) {
    eval { $node->remove() };
    is(''.$@,'');

    my $node2;
    eval { $node2 = Ravada::VM->open($node->id) };
    like($@,qr"can't find VM");
    ok(!$node2, "Expecting no node ".$node->id);
}
#############################################################

clean();

$Ravada::Domain::MIN_FREE_MEMORY = 256 * 1024;

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

    diag("Testing remote node in $vm_name");
    my $node = test_node($vm_name)  or next;

    ok($node->vm,"[$vm_name] expecting a VM inside the node") or do {
        remove_node($node);
        return;
    };

    test_start_twice($vm_name, $node);
    test_node_renamed($vm_name, $node);

    test_bases_node($vm_name, $node);
    test_domain_already_started($vm_name, $node);
    test_clone_not_in_node($vm_name, $node);
    test_rsync_newer($vm_name, $node);
    test_domain_no_remote($vm_name, $node);
    test_sync_base($vm_name, $node);

    my $domain2 = test_domain($vm_name, $node);
    test_remove_domain_from_local($vm_name, $node, $domain2)    if $domain2;

    my $domain3 = test_domain($vm_name, $node);
    test_remove_domain($vm_name, $node, $domain3)               if $domain3;

        test_domain_starts_in_same_vm($vm_name, $node);
        test_prepare_sets_vm($vm_name, $node);

    test_node_inactive($vm_name, $node);

#    _start_node($node);
#    clean_remote_node($node);
#    remove_node($node);
}

}

warn "cleaning";
clean();
warn "done testing";

done_testing();