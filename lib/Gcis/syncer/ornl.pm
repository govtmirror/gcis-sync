package Gcis::syncer::ornl;
use base 'Gcis::syncer';

use Gcis::Client;
use Gcis::syncer::util qw/:log iso_date pretty_id/;
use Smart::Comments;
use Mojo::UserAgent;
use Data::Dumper;
use DateTime;

use v5.14;
our $src = "http://mercury.ornl.gov/oai/provider";
our $records_per_request = 3;
our %params = (
  verb           => 'ListRecords',
  metadataPrefix => 'oai_dif',
  set            => sprintf('dleseodlsearch/./null/%d/%d','0',$records_per_request),
  #                          dleseodlsearch/[query]/[set]/[offset]/[length]
);

my $ua  = Mojo::UserAgent->new();

our $data_archive = '/organization/oak-ridge-national-laboratory';

our $map = {
    identifier  =>  sub { my $dom = shift;
                          my $id = $dom->at('header identifier')->text; 
                          $id =~ s[oai:mercury\.ornl\.gov:][];
                          $id =~ s/_/-/;
                          die "bad id : $id" unless $id =~ m[^ornldaac-\d+$];
                          return $id;
                        },
    native_id   =>  sub { shift->at('Entry_ID')->text; }, 
    name        =>  sub { shift->at('Entry_Title')->text;},
    description =>  sub { shift->at('Summary')->text;  },
    description_attribution => sub {
                           shift
                           ->find('Related_URL')
                           ->grep( sub { $_->at('Type') && $_->at('Type')->text =~ /view related information/i; })
                           ->map(at => 'URL')
                           ->map('text')->join(" ")->to_string;
                          },
    url => sub {
                           shift
                           ->find('Related_URL')
                           ->grep( sub { $_->at('Type') && $_->at('Type')->text =~ /get data/i; })
                           ->map(at => 'URL')
                           ->map('text')->join(" ")->to_string;
                          },
    doi         =>  sub { shift->find('Data_Set_Citation Other_Citation_Details')
                          ->map('text')
                          ->map(sub { s/doi://r })
                          ->join
                          ->to_string },
    lat_min      => sub { shift->at('Southernmost_Latitude')->text },
    lat_max      => sub { shift->at('Northernmost_Latitude')->text },
    lon_min      => sub { shift->at('Westernmost_Longitude')->text },
    lon_max      => sub { shift->at('Easternmost_Longitude')->text },
    start_time   => sub { shift->at('Temporal_Coverage Start_Date')->text },
    stop_time    => sub { shift->at('Temporal_Coverage Stop_Date')->text },
    release_dt   => sub { iso_date(shift->at('Dataset_Release_Date')->text) },
    access_dt    => sub { DateTime->now->iso8601 },
};

sub sync {
    my $s = shift;
    my %a = @_;
    my $limit   = $a{limit};
    my $dry_run = $a{dry_run};
    my $gcid_regex = $a{gcid};
    my $c       = $s->{gcis} or die "no client";
    my %stats;
    debug "starting ornl";

    my $per_page    = 10;
    my $more        = 1;
    my $start_index = 1;
    my $url         = Mojo::URL->new($src)->query(%params);
    my $count       = 0;

    REQUEST :
    while ($more) {
        $more = 0;
        info "getting $url";
        my $tx = $ua->get($url->query([ %params,
                set => sprintf('dleseodlsearch/./null/%d/%d',$count,$records_per_request),
            ]));
        my $res = $tx->success or die "$url : ".$tx->error->{message};
        if (my $error = $res->dom->at('error')) {
            info "ornl error : ".$error->text;
            return;
        }
        #debug "got ".$res->to_string;
        for my $entry ($res->dom->find('record')->each) {  ### Processing===[%]       done
            last REQUEST if $limit && ++$count > $limit;
            $more = 1;
            my %gcis_info = $s->_extract_gcis($entry);
            debug Dumper(\%gcis_info);

            # Store mappings to both shortName and id
##            my $dataset_gcid = $s->lookup_or_create_gcid(
##                  lexicon   => 'ornl',
##                  context => 'dataset',
##                  term    => $gcis_info{native_id},
##                  gcid    => "/dataset/$gcis_info{identifier}",
##                  dry_run => $dry_run,
##                  restrict => $gcid_regex,
##            );
##            die "bad gcid $dataset_gcid" if $dataset_gcid =~ / /;
##            next if $gcid_regex && $dataset_gcid !~ /$gcid_regex/;
##            my $alternate_id = $entry->at("id")->text;
##            $s->lookup_or_create_gcid(
##                lexicon => 'ornl', context => 'datasetId', term => $alternate_id,
##                gcid => $dataset_gcid, dry_run => $dry_run,
##            );
##
##            debug "entry #$count : $dataset_gcid";
##            $count++;
##
##            # insert or update
##            my $existing = $c->get($dataset_gcid);
##            my $url = $dataset_gcid;
##            $url = "/dataset" unless $existing;
##            $stats{ ($existing ? "updated" : "created") }++;
##            debug "sending to $url";
##            #debug Dumper(\%gcis_info);
##            unless ($dry_run) {
##                $c->post($url => \%gcis_info) or do {
##                    error "Error posting to $url : ".$c->error;
##                    error "Gcis info : ".Dumper(\%gcis_info);
##                };
##            }
        }
        $start_index += $per_page;
    }

    $s->{stats} = \%stats;
    return;
}
sub _extract_gcis {
    my $s = shift;
    my $dom = shift;
    our $map;

    my %new = map { $_ => $map->{$_}->( $dom ) } keys %$map;
    # debug "extracting $new{identifier} : $new{native_id}";
    return %new;
}
