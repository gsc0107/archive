#!/usr/bin/perl -w

#Written by Malachi Griffith
#The purpose of this script is to get gene/transcript/exon data from ensembl so that it can be populated to an ALEXA database for probe design
#The Ensembl perl API is used for all database interactions
#Ensembl genes will be retrieved as slices with respect to the genes themselves (and have coordinates will be relative to this genomic slice containing the gene)
#Each ensembl gene may have multiple transcripts.  These transcripts will consist of combinations of exons (some which overlap multiple transcripts and others
#that are unique to a single transcript).  Some exons may overlap exons from another transcript for the same gene.
#The full gene sequence will start with the first exon (from any transcript) and go until the end of the last exon (from any transcript)
#All genes from Ensembl will be populated to the database.  Further analysis will have to consider whether to include pseudogenes, mtRNA, miRNA, etc.

#NOTE: Before running this script you must have access to a local copy of an EnsEMBL data you which to use for probe design
#      - You must also have access to an empty ALEXA database which has been created.
#      - A new ALEXA database should be created for each species or EnsEMBL version to be used for probe design.

use DBI;
use strict;
use Data::Dumper;
use Getopt::Long;
use Benchmark;
use Term::ANSIColor qw(:constants);
use File::Basename;

#ALEXA libraries
#When a script is initiated, use the full path of the script location at execution to add the perl module libraries to @INC
#This should allow this scripts to work regardless of the current working directory or the script location (where it was unpacked).
#The /utilities directory must remain in the same directory as this script but the entire code directory can be moved around
BEGIN {
  my $script_dir = &File::Basename::dirname($0);
  push (@INC, $script_dir);
}
use utilities::utility qw(:all);
use utilities::ALEXA_DB qw(:all);

#Initialize command line options
my $ensembl_api_version = ''; #Version of EnsEMBL to use
my $ensembl_database = '';
my $ensembl_server = '';
my $ensembl_user = '';
my $ensembl_password = '';
my $alexa_database = '';
my $alexa_server = '';
my $alexa_user = '';
my $alexa_password = '';
my $single_id = '';
my $all_ids = '';
my $populate_database = '';
my $logfile = '';

GetOptions ('ensembl_api_version=s'=>\$ensembl_api_version,
	    #Source database access
	    'ensembl_database=s'=>\$ensembl_database, 'ensembl_server=s'=>\$ensembl_server, 'ensembl_user=s'=>\$ensembl_user, 'ensembl_password=s'=>\$ensembl_password,
	    #Target database access
	    'alexa_database=s'=>\$alexa_database, 'alexa_server=s'=>\$alexa_server, 'alexa_user=s'=>\$alexa_user, 'alexa_password=s'=>\$alexa_password,
	    'single_id=s'=>\$single_id, 'all_ids=i'=>\$all_ids, 'populate_database=s'=>\$populate_database, 'logfile=s'=>\$logfile);

#Provide instruction to the user
print GREEN, "\n\nNOTE: Before using this script, make sure the correct API version is hard coded!!\n\n", RESET;
print GREEN, "\n\nUsage:", RESET;
print GREEN, "\n\tSpecify the correct EnsEMBL API version using: --ensembl_api_version (41, 42, etc.)", RESET;
print GREEN, "\n\tSpecify the SOURCE Ensembl Database and Server using: --ensembl_database and --ensembl_server", RESET;
print GREEN, "\n\tSpecify the Ensembl User and Password for access using: --ensembl_user and --ensembl_password\n", RESET;
print GREEN, "\n\tSpecify the TARGET Database and Server to query using: --alexa_database and --alexa_server", RESET;
print GREEN, "\n\tSpecify the User and Password for access using: --alexa_user and --alexa_password\n", RESET;
print GREEN, "\n\tTo test, specify a single id using: --single_id (say ENSG00000171163)", RESET;
print GREEN, "\n\tTo process all genes use: --all_ids=1", RESET;
print GREEN, "\n\tAfter testing, import data to specified ALEXA database using: --populate_database=yes", RESET;
print GREEN, "\n\tSpecify a logfile for output using: --logfile", RESET;
print GREEN, "\n\nExample: getEnsemblGeneData.pl  --ensembl_api_version=41  --ensembl_database=homo_sapiens_core_41_36c  --ensembl_server=source_server  --ensembl_user=ensembl_user  --ensembl_password=pwd  --alexa_database=ALEXA_hs_41_36c  --alexa_server=target_server  --alexa_user=user  --alexa_password=pwd  --all_ids=1  --populate_database=no  --logfile=/home/user/alexa/ALEXA_version/logs/database_population/getEnsemblGeneData_LOG.txt\n\n", RESET;

unless ($ensembl_api_version && $ensembl_database && $ensembl_server && $ensembl_user && $ensembl_password && $alexa_database && $alexa_server && $alexa_user && $alexa_password && $populate_database && $logfile){
  print RED, "\nRequired input parameter(s) missing\n\n", RESET;
  exit();
}

#**********************************************************************************************************
#IMPORTANT NOTE: You must have the correct Ensembl API installed locally AND bioperl 1.2 or greater!!
#Both the EnsEMBL core API as well as Compara are required
#Refer to the ALEXA manual for additional details on how to install these
#Then update the following paths:
if ($ensembl_api_version =~ /^\d+/){

  if ($ensembl_api_version eq "35"){
    unshift(@INC, "/home/malachig/perl/ensembl_35_perl_API/ensembl/modules");
  }elsif ($ensembl_api_version eq "41"){
    unshift(@INC, "/home/malachig/perl/ensembl_41_perl_API/ensembl/modules");

  }elsif($ensembl_api_version eq "42"){
    unshift(@INC, "/home/malachig/perl/ensembl_42_perl_API/ensembl/modules");

  }elsif($ensembl_api_version eq "43"){
    unshift(@INC, "/home/malachig/perl/ensembl_43_perl_API/ensembl/modules");

  }else{
    print RED, "\nEnsEMBL API version: $ensembl_api_version is not defined, modify script before proceeding\n\n", RESET;
    exit();
  }

}else{
  print RED, "\nEnsEMBL API version format: $ensembl_api_version not understood!\n\n", RESET;
  exit();
}
use lib "/home/malachig/perl/bioperl-1.4";    #Bioperl
#*********************************************************************************************************
#print Dumper @INC;
require Bio::EnsEMBL::DBSQL::DBAdaptor;

unless ($single_id || $all_ids){
  print RED, "\n\tSpecify --single_id or --all_ids\n\n", RESET;
  print RED, "\tTo test on a single ensembl ID: use --single_id=valid_ensembl_id\n", RESET;
  print RED, "\te.g. --single_id=ENSG00000171163\n", RESET;
  print RED, "\tUse --all_ids=1 to process all ensembl genes\n\n", RESET;
  exit();
}
unless ($populate_database eq "yes"){
  print YELLOW, "Once you have completed testing: Use -all_ids=1 and --populate_database=yes to process all genes and insert to database\n", RESET;
}

#Open logfile for output
open (LOG, ">$logfile") || die "\nCould not open logfile: $logfile\n\n";

print LOG "\nUser Specified the following options:\nensembl_database = $ensembl_database\nalexa_database = $alexa_database\nsingle_id = $single_id\nall_ids = $all_ids\npopulate_database = $populate_database\nlogfile = $logfile\n\n";

#1.) Establish connections to source EnsEMBL database and target ALEXA databases

#A.) Using a local ensembl version
#Get a connection to the local Ensembl database
my $ensembl_api = new Bio::EnsEMBL::DBSQL::DBAdaptor(-host => $ensembl_server,
						    -user => $ensembl_user,
						    -dbname => $ensembl_database,
						    -pass => $ensembl_password);

#Alternatively you might try getting a connection to the Ensembl server itself over the internet
#This will be much slower but you can try something like this:
#my $ensembl_api = new Bio::EnsEMBL::DBSQL::DBAdaptor(-host => 'ensembldb.ensembl.org',
#						      -user => 'anonymous',
#						      -dbname => 'homo_sapiens_core_41_36c');

#2.) Establish connection with the Alternative Splicing Expression database using details provided by user
my $alexa_dbh = &connectDB('-database'=>$alexa_database, '-server'=>$alexa_server, '-user'=>$alexa_user, '-password'=>$alexa_password);

#Make sure the max allowed packet size is large enough to allow large genes
&checkMaxPacketSize('-dbh'=>$alexa_dbh);

my $ensembl_ids_ref;
if ($single_id){
  $ensembl_ids_ref->{$single_id}->{gene_type} = "TESTING";
}elsif($all_ids eq "1"){
  #Get all ensembl IDs for processing
  $ensembl_ids_ref = &getAllEnsemblIds();
}

my $source = $ensembl_database;

my $gene_count = 0;
my $known_gene_count = 0;
my $unknown_gene_count = 0;
my $gene_update_count = 0;
my $chr_strand;

foreach my $ensembl_id (sort keys %{$ensembl_ids_ref}){
  my $t0 = new Benchmark;
  my %gene_info;
  my $gene_info_ref = \%gene_info;
  $gene_count++;

  #A Slice object represents a continuous region of a genome
  my $slice_adaptor = $ensembl_api->get_SliceAdaptor();

  #Retrieve a slice with respect to a gene, with a specified flanking sequence on either side
  my $slice = $slice_adaptor->fetch_by_gene_stable_id($ensembl_id, 0);

  #Check the strand of the target gene within this strand.  If it is on the reverse strand - invert the slice and continue
  $chr_strand = 1; #Initialize to 1, switch to -1 if gene is on reverse strand.

  $slice = check_strand('-slice_obj'=>$slice, '-ensembl_id'=>$ensembl_id);

  #Determine the coordinate system used here - should be chromosome.
  #These coordinates can be used to map the location of genes, transcripts, and exons to their chromosomal positions
  my $coord_sys = $slice->coord_system()->name();
  my $chr = $slice->seq_region_name();

  my $chr_start = $slice->start();
  my $chr_end = $slice->end();

  #Remember this slice may contain more than one gene if there are overlapping genes
  foreach my $gene (@{$slice->get_all_Genes()}){

    #Make sure the right gene is being considered and not an overlapping gene (which will be processed individually)
    my $gene_id = $gene->stable_id();
    unless ($gene_id eq $ensembl_id){
      next();
    }

    my $test_name = $gene->external_name();
    if ($test_name){
      $known_gene_count++;
    }
    unless ($test_name){
      $test_name = "Unknown";
      $unknown_gene_count++;
    }
    print BLUE, "\n$gene_count -> Gene NAME: $test_name ($ensembl_id)", RESET;
    print LOG "\n$gene_count -> Gene NAME: $test_name ($ensembl_id)";

    #Transform the coordinates to chromosome system
    if (my $new_gene = $gene->transform('chromosome')){

      my $chr_test = $new_gene->slice->seq_region_name();
      my $chr_start_test = $new_gene->start();
      my $chr_end_test = $new_gene->end();
      my $strand_test = $new_gene->strand();

      print BLUE, "\n\tChr Coordinates: $strand_test $chr_test ($chr_start_test - $chr_end_test)", RESET;
      print LOG "\n\tChr Coordinates: $strand_test $chr_test ($chr_start_test - $chr_end_test)";

    }else{
      print YELLOW, "\n\tFeature is not defined in chromosome coordinate system", RESET;
      print LOG "\n\tFeature is not defined in chromosome coordinate system";
    }

    #Get all useful gene info for this ensembl id (HUGO, refseq, GO, OMIM, etc.)
    &getBasicGeneInfo('-ensembl_gene_obj'=>$gene, '-ensembl_id'=>$ensembl_id, '-gene_object'=>$gene_info_ref);

    #Get the entire sequence for this gene (from start of 1st exon to end of last exon, including introns)
    my $full_gene_sequence = $slice->seq();

    $gene_info_ref->{$ensembl_id}->{sequence} = $full_gene_sequence;

    my $gene_details_ref = &feature_details('-feature_obj'=>$gene);

    $gene_info_ref->{$ensembl_id}->{chr_strand} = $chr_strand;
    $gene_info_ref->{$ensembl_id}->{corrected_strand} = $gene_details_ref->{$gene_id}->{strand};
    $gene_info_ref->{$ensembl_id}->{chromosome} = $gene_details_ref->{$gene_id}->{chromosome};
    $gene_info_ref->{$ensembl_id}->{chr_start} = $chr_start;
    $gene_info_ref->{$ensembl_id}->{chr_end} = $chr_end;
    $gene_info_ref->{$ensembl_id}->{gene_start} = $gene_details_ref->{$gene_id}->{start};
    $gene_info_ref->{$ensembl_id}->{gene_end} = $gene_details_ref->{$gene_id}->{end};

    my %transcripts;
    foreach my $trans (@{$gene->get_all_Transcripts()}){
      my $trans_id = $trans->stable_id();

      my $trans_details_ref = &feature_details('-feature_obj'=>$trans);
      $transcripts{$trans_id}{start} = $trans_details_ref->{$trans_id}->{start};
      $transcripts{$trans_id}{end} = $trans_details_ref->{$trans_id}->{end};

      my %exons;
      foreach my $exon (@{$trans->get_all_Exons()}){
	my $exon_id = $exon->stable_id();

	my $exon_details_ref = &feature_details('-feature_obj'=>$exon);
	$exons{$exon_id}{start} = $exon_details_ref->{$exon_id}->{start};
	$exons{$exon_id}{end} = $exon_details_ref->{$exon_id}->{end};

      }
      $transcripts{$trans_id}{exons} = \%exons;

      #Get all useful IDs for every transcript of every gene
      my %external_ids;
      #foreach my $link (@{$trans->get_all_DBLinks()}) {
#	my $link_id = $link->display_id;
#	my $link_database = $link->database;

	#Eliminate redundancies if they exist (shouldnt be redundant at transcript level)
#	$external_ids{$link_id}{type} = $link_database;
#      }

      $transcripts{$trans_id}{external_ids} = \%external_ids;

      #Get CDS start and end info for each transcript (get genomic coordinates, not those relative to the cDNA)
      my $coding_region_start = $trans->coding_region_start();
      my $coding_region_end = $trans->coding_region_end();

      #Pseudogenes and RNA genes will not have a cDNA start and end.  Set to 'na'
      my @cds_starts;
      my @cds_ends;
      if ($coding_region_start && $coding_region_end){

	my $cdna_start = $trans->cdna_coding_start();
	my $cdna_end = $trans->cdna_coding_end();

	my $trmapper = Bio::EnsEMBL::TranscriptMapper->new($trans);
	my @genomic_coords = $trmapper->cdna2genomic($cdna_start,$cdna_end);

	foreach my $gc (@genomic_coords){
	  my $gc_start = $gc->start();
	  my $gc_end = $gc->end();
	  push(@cds_starts,$gc_start);
	  push(@cds_ends, $gc_end);
	}

      }else{
	$coding_region_start = 'na';
	$coding_region_end = 'na';
	push(@cds_starts, 'na');
	push(@cds_ends, 'na');
      }

      $transcripts{$trans_id}{coding_region_start} = $coding_region_start;
      $transcripts{$trans_id}{coding_region_end} = $coding_region_end;
      $transcripts{$trans_id}{cds_starts} = \@cds_starts;
      $transcripts{$trans_id}{cds_ends} = \@cds_ends;

      #Get protein feature info for each transcript (things like protein domains, transmembrane domains, etc.)
      my %protein_features;
      my $pf_count = 0;

      #Note that not all transcripts will have a translation (pseudogenes, rna genes, etc.).
      my $translation = $trans->translation();

      #If a translation is not defined then do not search for protein features
      if($translation){
	my $protein_features = $translation->get_all_ProteinFeatures();

	foreach my $pf (@$protein_features){
	  $pf_count++;
	  my $logic_name = $pf->analysis()->logic_name();
	  my $pf_start = $pf->start();
	  my $pf_end = $pf->end();
	  my $interpro_ac = $pf->interpro_ac();     #not always defined
	  my $idesc = $pf->idesc();                 #not always defined
	  my $program = $pf->analysis()->program(); #not always defined

	  unless ($interpro_ac){$interpro_ac = 'na'};
	  unless ($idesc){$idesc = 'na'};
	  unless ($program){$program = 'na'};

	  #Convert protein coordinates to gene coordinates for storage
	  #This will return coordinate for each exon involved in this protein domain.
	  #The start and end will be stored, but all coordinates will also be stored for convenience
	  my $trmapper = Bio::EnsEMBL::TranscriptMapper->new($trans);
	  my @genomic_coords = $trmapper->pep2genomic($pf_start,$pf_end);

	  my $pf_gene_start = $genomic_coords[0]->start();
	  my $pf_gene_end = $genomic_coords[0]->end();
	  my @pf_starts;
	  my @pf_ends;
	  foreach my $gc (@genomic_coords){
	    my $gc_start = $gc->start();
	    my $gc_end = $gc->end();

	    if ($gc_start < $pf_gene_start){
	      $pf_gene_start = $gc_start;
	    }
	    if ($gc_end > $pf_gene_end){
	      $pf_gene_end = $gc_end;
	    }
	    push(@pf_starts,$gc_start);
	    push(@pf_ends, $gc_end);
	  }

	  #print "\n\tDEBUG: PF: $logic_name, $interpro_ac, $idesc, $program, $pf_gene_start, $pf_gene_end";

	  $protein_features{$pf_count}{logic_name} = $logic_name;
	  $protein_features{$pf_count}{interpro_ac} = $interpro_ac;
	  $protein_features{$pf_count}{idesc} = $idesc;
	  $protein_features{$pf_count}{program} = $program;
	  $protein_features{$pf_count}{start} = $pf_gene_start;
	  $protein_features{$pf_count}{end} = $pf_gene_end;
	  $protein_features{$pf_count}{start_coords} = \@pf_starts;
	  $protein_features{$pf_count}{end_coords} = \@pf_ends;
	}
      }else{
	print YELLOW, "\n\tNOTE: Gene $ensembl_id does not have a translation", RESET;
	print LOG "\n\tNOTE: Gene $ensembl_id does not have a translation";
      }
      $transcripts{$trans_id}{protein_features} = \%protein_features;
    }

    $gene_info_ref->{$ensembl_id}->{trans} = \%transcripts;

  }

  #Populate the database with this gene record if the user specified the -d flag
  if ($populate_database eq "yes"){
    $gene_update_count++;
    &populateDatabase('-gene_object'=>$gene_info_ref);
    my $t1 = new Benchmark;
    my $td1 = timediff($t1, $t0);
    print BLUE, "\n\n$gene_update_count Genes Inserted to Database\tElapsed Time:",timestr($td1),"\n", RESET;
    print LOG "\n\n$gene_update_count Genes Inserted to Database\tElapsed Time:",timestr($td1),"\n";
  }
}

#Close database connection
$alexa_dbh->disconnect();

print BLUE, "\n\nProcessed a total of $gene_count genes: $known_gene_count are KNOWN, $unknown_gene_count are UNKNOWN (predicted only)\n", RESET;
print LOG "\n\nProcessed a total of $gene_count genes: $known_gene_count are KNOWN, $unknown_gene_count are UNKNOWN (predicted only)\n";

print "\n\n";
print LOG "\n\n";
close (LOG);

exit();


##############################################################################################
#Get all ensembl Ids from the local ensembl database that are appropriate                    #
##############################################################################################
sub getAllEnsemblIds{
  my %ids;

  #Get a normal DBI connection to the ensembl database
  my $ensembl_dbh = &connectDB('-database'=>$ensembl_database, '-server'=>$ensembl_server, '-user'=>$ensembl_user, '-password'=>$ensembl_password);

  #Get the gene sequence for this gene
  my $sql = "SELECT gene.gene_id,stable_id,biotype FROM gene,gene_stable_id WHERE gene_stable_id.gene_id = gene.gene_id;";
  my $sth = $ensembl_dbh->prepare("$sql");
  $sth->execute();

  while (my ($gene_id,$ensembl_id,$gene_type) = $sth->fetchrow_array()){
    $ids{$ensembl_id}{ensembl_internal_id} = $gene_id;
    $ids{$ensembl_id}{gene_type} = $gene_type;
  }

  $sth->finish();

  $ensembl_dbh->disconnect();

  return(\%ids);
}


###################################################################################
#For a given target gene, determine the strand of this gene in its genomic slice  #
#If it is on the reverse strand, invert the entire slice and return it            #
###################################################################################
sub check_strand{
  my %args = @_;
  my $slice = $args{'-slice_obj'};
  my $ensembl_id = $args{'-ensembl_id'};

  foreach my $gene (@{$slice->get_all_Genes()}){

    #Make sure the right gene is being considered and not an overlapping gene (which will be processed individually)
    my $gene_id = $gene->stable_id();

    unless ($gene_id eq $ensembl_id){
      next();
    }

    #If the gene is on the reverse strand with respect to the slice, invert the slice
    my $strand_test = $gene->strand();

    if ($strand_test eq "-1"){
      #print "\nFeature is on reverse strand - inverting\n\n";
      $slice = $slice->invert();
      $chr_strand = -1;
    }
  }
  return ($slice);
}

##################################################################################
#Get external descriptive information if a gene is known                         #
##################################################################################
sub getBasicGeneInfo{
  my %args = @_;

  my $gene = $args{'-ensembl_gene_obj'};
  my $ensembl_id = $args{'-ensembl_id'};
  my $gene_object_ref = $args{'-gene_object'};

  my $gene_name = $gene->external_name();

  unless ($gene_name){
    $gene_name = "Unknown";
  }

  #Get the gene type
  my $gene_type = $gene->biotype();

  #Get the gene version
  my $ensembl_version = $gene->version();

  $gene_object_ref->{$ensembl_id}->{source} = $source;
  $gene_object_ref->{$ensembl_id}->{gene_type} = $gene_type;
  $gene_object_ref->{$ensembl_id}->{gene_name} = $gene_name;
  $gene_object_ref->{$ensembl_id}->{ensembl_version} = $ensembl_version;

  if ($gene->is_known()) {
    $gene_object_ref->{$ensembl_id}->{evidence} = "Known Gene";
  }else{
    $gene_object_ref->{$ensembl_id}->{evidence} = "Unknown Gene";
    print YELLOW, "\n\tNOTE: Gene " . $gene->stable_id() . " is not a known gene", RESET;
    print LOG "\n\tNOTE: Gene " . $gene->stable_id() . " is not a known gene";
  }

  return();
}

######################################################################
#Populate the database with Gene, Transcript, Exon info              #
######################################################################
sub populateDatabase{
  my %args = @_;
  my $gene_object = $args{'-gene_object'};

  foreach my $ensg_id (sort keys %{$gene_object}){

    #1.)Insert gene into gene table
    my $sql_gene = "INSERT INTO Gene (ensembl_g_id,ensembl_version,source,gene_type,gene_name,evidence,sequence,chr_strand,corrected_strand,chromosome,chr_start,chr_end,gene_start,gene_end) VALUES (\'$ensg_id\',\'$gene_object->{$ensg_id}->{ensembl_version}\',\'$gene_object->{$ensg_id}->{source}\',\'$gene_object->{$ensg_id}->{gene_type}\',\'$gene_object->{$ensg_id}->{gene_name}\',\'$gene_object->{$ensg_id}->{evidence}\',\'$gene_object->{$ensg_id}->{sequence}\',\'$gene_object->{$ensg_id}->{chr_strand}\',\'$gene_object->{$ensg_id}->{corrected_strand}\',\'$gene_object->{$ensg_id}->{chromosome}\',\'$gene_object->{$ensg_id}->{chr_start}\',\'$gene_object->{$ensg_id}->{chr_end}\',\'$gene_object->{$ensg_id}->{gene_start}\',\'$gene_object->{$ensg_id}->{gene_end}\');";

    my $sth_gene = $alexa_dbh->prepare("$sql_gene");
    $sth_gene->execute();
    $sth_gene->finish();

    my $gene_id = $alexa_dbh->{'mysql_insertid'};

    print BLUE, "\n->New Gene Record: $gene_id", RESET;
    print LOG "\n->New Gene Record: $gene_id";

    #2.) Insert each transcript for this gene and relate it to the parent gene
    my $transcripts_ref = $gene_object->{$ensg_id}->{trans};
    foreach my $enst_id (sort keys %{$transcripts_ref}){

      #Make sure this transcript has not already been entered (look for one transcript linked to more than one ensembl gene)
      my $sql_test1 = "SELECT id FROM Transcript WHERE ensembl_t_id = '$enst_id'";
      my $sth_test1 = $alexa_dbh->prepare("$sql_test1");
      $sth_test1->execute();
      my $t_id = $sth_test1->fetchrow_array();
      $sth_test1->finish();

      if ($t_id){
	print RED, "\nWARNING: Transcript: $t_id was already in the database!\n\n", RESET;
	print LOG "\nWARNING: Transcript: $t_id was already in the database!\n\n";
      }

      my $sql_trans = "INSERT INTO Transcript (fk_Gene__id,ensembl_t_id,start,end,coding_region_start,coding_region_end,cds_start_coords,cds_end_coords) VALUES (\'$gene_id\',\'$enst_id\',\'$transcripts_ref->{$enst_id}->{start}\',\'$transcripts_ref->{$enst_id}->{end}\',\'$transcripts_ref->{$enst_id}->{coding_region_start}\',\'$transcripts_ref->{$enst_id}->{coding_region_end}\',\'@{$transcripts_ref->{$enst_id}->{cds_starts}}\',\'@{$transcripts_ref->{$enst_id}->{cds_ends}}\');";

      my $sth_trans = $alexa_dbh->prepare("$sql_trans");
      $sth_trans->execute();
      $sth_trans->finish();

      my $trans_id = $alexa_dbh->{'mysql_insertid'};

      print BLUE, "\n\t->New Transcript Record: $trans_id", RESET;
      print LOG "\n\t->New Transcript Record: $trans_id";

      #3) Insert all the external IDs for this transcript (HUGO, Refseq, etc. etc.)
      #my $external_id_count = 0;

      #my $external_ids_ref = $transcripts_ref->{$enst_id}->{external_ids};

      #Get the number of external ID entries needed for this transcript
      #my $num_ids = keys %{$external_ids_ref};

      #my $sql1 = "INSERT INTO External_id (fk_Transcript__id,type,external_id) VALUES ";

      #foreach my $external_id (sort keys %{$external_ids_ref}){
#	$external_id_count++;
#	my $external_id_type = $external_ids_ref->{$external_id}->{type};

	#If this is the last external ID for this transcript, do the multiple insert
#	if ($external_id_count == $num_ids){
	  #Add insert record onto end, but omit the comma since this is the last one of this block
#	  $sql1 = "$sql1"."($trans_id,\'$external_id_type\',\'$external_id\');";

	  #Actually do the insert!
#	  my $sth1 = $alexa_dbh->prepare("$sql1");
#	  $sth1->execute();
#	  $sth1->finish();

#	  print BLUE, "\n\t\t->Entered $external_id_count link Ids", RESET;
#	  print LOG "\n\t\t->Entered $external_id_count link Ids";

#	}else{
#	  $sql1 = "$sql1"."($trans_id,\'$external_id_type\',\'$external_id\'),";
#	}
#      }

      #4.) Insert all of the protein features for this transcript
      my $protein_feature_count = 0;

      my $protein_features_ref = $transcripts_ref->{$enst_id}->{protein_features};

      #Get the number of protein feature entries needed for this transcript
      my $num_features = keys %{$protein_features_ref};

      my $sql_pf = "INSERT INTO Protein_feature (fk_Transcript__id,type,interpro_ac,name,program,start,end,start_coords,end_coords) VALUES ";

      foreach my $pf_count (sort {$a <=> $b} keys %{$protein_features_ref}){
	$protein_feature_count++;

	#If this is the last feature for this transcript, do the multiple insert
	if ($protein_feature_count == $num_features){
	  #Add insert record onto end, but omit the comma since this is the last one of this block
	  $sql_pf = "$sql_pf"."($trans_id,\'$protein_features_ref->{$pf_count}->{logic_name}\',\'$protein_features_ref->{$pf_count}->{interpro_ac}\',\'$protein_features_ref->{$pf_count}->{idesc}\',\'$protein_features_ref->{$pf_count}->{program}\',\'$protein_features_ref->{$pf_count}->{start}\',\'$protein_features_ref->{$pf_count}->{end}\',\'@{$protein_features_ref->{$pf_count}->{start_coords}}\',\'@{$protein_features_ref->{$pf_count}->{end_coords}}\');";

	  #Actually do the insert!
	  my $sth_pf = $alexa_dbh->prepare("$sql_pf");
	  $sth_pf->execute();
	  $sth_pf->finish();

	  print BLUE, "\n\t\t->Entered $protein_feature_count protein features", RESET;
	  print LOG "\n\t\t->Entered $protein_feature_count protein features";

	}else{
	  $sql_pf = "$sql_pf"."($trans_id,\'$protein_features_ref->{$pf_count}->{logic_name}\',\'$protein_features_ref->{$pf_count}->{interpro_ac}\',\'$protein_features_ref->{$pf_count}->{idesc}\',\'$protein_features_ref->{$pf_count}->{program}\',\'$protein_features_ref->{$pf_count}->{start}\',\'$protein_features_ref->{$pf_count}->{end}\',\'@{$protein_features_ref->{$pf_count}->{start_coords}}\',\'@{$protein_features_ref->{$pf_count}->{end_coords}}\'),";
	}
      }

      #5.) Insert each exon for this transcript and relate it to the parent transcript
      #Make sure it hasn't been entered already for a different transcript of this gene - this is expected
      my $exons_ref = $transcripts_ref->{$enst_id}->{exons};
      my $num_exons = keys %{$exons_ref};

      my $trans_exon_count = 0;

      my $sql2 = "INSERT INTO TranscriptExon (fk_Transcript__id,fk_Exon__id) VALUES ";

      foreach my $ense_id (sort keys %{$exons_ref}){
	$trans_exon_count++;

	#Check if theis exon has already been entered for another transcript
	my $sql_test2 = "SELECT id FROM Exon WHERE ensembl_e_id = '$ense_id'";
	my $sth_test2 = $alexa_dbh->prepare("$sql_test2");
	$sth_test2->execute();
	my $e_id = $sth_test2->fetchrow_array();
	$sth_test2->finish();

	#If the exon is already there, simply create a new relationship to it's parent transcript
	if ($e_id){

	  #If this is the last exon for this transcript, finish up the sql multiple query (otherwise just add it on):
	  if($trans_exon_count == $num_exons){
	    $sql2 = "$sql2"."($trans_id,$e_id);";
	  }else{
	    $sql2 = "$sql2"."($trans_id,$e_id),";
	  }

	}else{
	  #If the exon is not already entered, enter it now.

	  my $sql_exon = "INSERT INTO Exon (ensembl_e_id,start,end) VALUES (\'$ense_id\',\'$exons_ref->{$ense_id}->{start}\',\'$exons_ref->{$ense_id}->{end}\');";

	  my $sth_exon = $alexa_dbh->prepare("$sql_exon");
	  $sth_exon->execute();
	  $sth_exon->finish();

	  my $new_exon_id = $alexa_dbh->{'mysql_insertid'};

	  print BLUE, "\n\t\t->New Exon Record: $new_exon_id", RESET;
	  print LOG "\n\t\t->New Exon Record: $new_exon_id";

	  #Again, if this is the last exon for this transcript, finish up the sql multiple query (otherwise just add it on):
	  if($trans_exon_count == $num_exons){
	    $sql2 = "$sql2"."($trans_id,$new_exon_id);";
	  }else{
	    $sql2 = "$sql2"."($trans_id,$new_exon_id),";
	  }
	}
      }
      #Actually insert all the TranscriptExon relationships for this transcript before going on to the next one.
      my $sth2 = $alexa_dbh->prepare("$sql2");
      $sth2->execute();
      $sth2->finish();

      print BLUE, "\n\t\t->Entered $trans_exon_count TranscriptExon Relationships", RESET;
      print LOG "\n\t\t->Entered $trans_exon_count TranscriptExon Relationships";
    }
  }
  return();
}


########################################################################
#For any basic feature, get basic details and return as hash keyed on  #
#the stable id                                                         #
########################################################################
sub feature_details {
  my %args = @_;
  my $f = $args{'-feature_obj'};

  my %feature;

  my $stable_id = $f->stable_id();

  $feature{$stable_id}{chromosome} = $f->slice->seq_region_name();
  $feature{$stable_id}{start} = $f->start();
  $feature{$stable_id}{end} = $f->end();
  $feature{$stable_id}{strand} = $f->strand();

  return (\%feature);
}
