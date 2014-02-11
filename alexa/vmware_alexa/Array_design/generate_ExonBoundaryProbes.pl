#!/usr/bin/perl -w

#Written by Malachi Griffith
#The purpose of this script is to generate all possible exon-intron junction probes for each ensembl gene
#The user can specify a probe length, which must be an even number for simplicity. The resulting probes will be centered on the junction.

#Note: Intron-exon probes can potentially be used to detect intron inclusion events.  For overlapping exons, the case is not so simple.
#In this case the 'Intron-exon' probe is actually spanning an alternate splice site at the 3' or 5' end of the exon.
#In fact any time expression seems to be present for an intron-exon probe it may be an indication that an alternate splice site is being used
#In other words, it doesn't neccessarily mean that an intron was included, it may also mean that the exon is simply longer than expected because
#an alternate 5' or 3' splice site was used.

#Probes will be centered on the junction and the length will be modified to achieve the closest Tm to the target
#The probe length will not be allowed to extend or shorten beyond a limit set by the user (max_length_variance)
#This allows the user to retrieve isothermal probes for each junction.
#However, if the user wishes to have probes of a set length regardless of the Tm, they can simply specify a max_length_variance of 0

#The user will also be allowed to specify the number of probes returned for each junction, generated by increasing or decreasing the probe length
#These will be returned in order according to how closely they match the target Tm
#This is only applicable if the user has allowed the probe length to vary

#To allow for testing of this script, the user can also specify a single target Ensembl gene ID or design probes for all Ensembl Genes
#If the user specifies to get probes for all genes, only 'Known' and 'Non-Pseudo' genes will be analyzed

use strict;
use Data::Dumper;
use Getopt::Long;
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
use utilities::Probes qw(:all);

#Initialize command line options
my $database = '';
my $server = '';
my $user = '';
my $password = '';
my $target_tm = '';
my $target_length = '';
my $max_length_variance = '';
my $probes_per_junction = '';
my $ensembl_gene_id = '';
my $all_genes = '';
my $allow_predicted_genes = '';
my $verbose = '';
my $probe_dir = '';
my $outfile = '';
my $logfile = '';
my $ignore_masking = '';

GetOptions ('database=s'=>\$database,'server=s'=>\$server, 'user=s'=>\$user, 'password=s'=>\$password,
	    'target_tm=f'=>\$target_tm, 'target_length=i'=>\$target_length, 'max_length_variance=i'=>\$max_length_variance,
	    'ensembl_gene_id=s'=>\$ensembl_gene_id, 'all_genes=s'=>\$all_genes, 'allow_predicted_genes=s'=>\$allow_predicted_genes,
	    'probes_per_junction=i'=>\$probes_per_junction, 'verbose=s'=>\$verbose, 'probe_dir=s'=>\$probe_dir, 'outfile=s'=>\$outfile, 
	    'logfile=s'=>\$logfile, 'ignore_masking=s'=>\$ignore_masking);

#Provide instruction to the user
print GREEN, "\n\nUsage:", RESET;
print GREEN, "\n\tSpecify the database and server to query using: --database and --server", RESET;
print GREEN, "\n\tSpecify the user and password for access using: --user and --password", RESET;
print GREEN, "\n\tSpecify the target Tm for probe sequences using: --target_tm (eg. 67.0)", RESET;
print GREEN, "\n\tSpecify the target probe length (must be a multiple of 2) using: --target_length (eg. 36)", RESET;
print GREEN, "\n\tSpecify the maximum this probe length will be allowed to vary using: --max_length_variance (eg. 10)", RESET;
print GREEN, "\n\tSpecify the desired number of probes per junction to return using: --probes_per_junction (eg. 2)", RESET;
print GREEN, "\n\t\tIf you want to test with a single gene ID use: --ensembl_gene_id (ENSG00000000003)", RESET;
print GREEN, "\n\t\tIf you want to design probes for all genes, use: --all_genes=yes", RESET;
print GREEN, "\n\t\tIf you wish to allow predicted genes (for species with few known genes), use: --allow_predicted_genes=yes", RESET;
print GREEN, "\n\t\tIf you want verbose output, use: --verbose=yes", RESET;
print GREEN, "\n\t\tIf you want to disregard masking for some reason (not recommended) use: --ignore_masking=yes", RESET;
print GREEN, "\n\tSpecify the path to the directory of current probe files (used to determine starting probe ID value) using: --probe_dir", RESET;
print GREEN, "\n\tSpecify the name of the output probe file: --outfile", RESET;
print GREEN, "\n\tAlso specify the name of a log file to be used to store a record of the design process using: --logfile", RESET;
print GREEN, "\n\nExample: generate_ExonBoundaryProbes.pl  --database=ALEXA_hs_35_35h  --server=server_name  --user=user_name  --password=pwd  --target_tm=67.0  --target_length=36  --max_length_variance=10  --probes_per_junction=3  --allow_predicted_genes=no  --all_genes=yes  --probe_dir=/home/user/alexa/ALEXA_version/unfiltered_probes/  --outfile=/home/user/alexa/ALEXA_version/unfiltered_probes/exonBoundaryProbes.txt  --logfile=/home/user/alexa/ALEXA_version/logs/generate_ExonBoundaryProbes_LOG.txt\n\n", RESET;

#Make sure all options were specified
unless ($database && $server && $user && $password && $target_tm && $target_length && ($max_length_variance || $max_length_variance eq "0") && $probes_per_junction && $allow_predicted_genes && $probe_dir && $outfile && $logfile){
  print RED, "\nRequired input parameter(s) missing!\n\n", RESET;
  exit();
}
if ($max_length_variance eq "0" && $probes_per_junction > 1){
  print RED, "\nIf max variance in length is specified as 0, only 1 probe can be found!!\n\n", RESET;
  exit();
}

#Get the starting probe_id and probeset_id by examining the specified input probe file directory.  If it is empty start with 1
my @current_ids = &getCurrentProbeIds('-probe_dir'=>$probe_dir);
my $current_probe_id = $current_ids[0];          #Unique probe ID used for each successful probe
my $current_probeset_id = $current_ids[1];       #Unique count of exon-exon junctions with successful probes

#Establish connection with the Alternative Splicing Expression database
my $alexa_dbh = &connectDB('-database'=>$database, '-server'=>$server, '-user'=>$user, '-password'=>$password);

open (LOG, ">$logfile") || die "\nCould not open logfile: $logfile\n\n";

#Print out the parameters supplied by the user to the logfile for future reference
print LOG "\nUser Specified the following options:\ndatabase = $database\ntarget_tm = $target_tm\ntarget_length = $target_length\nmax_length_variance = $max_length_variance\nprobes_per_junction = $probes_per_junction\nensembl_gene_id = $ensembl_gene_id\nall_genes = $all_genes\nallow_predicted_genes = $allow_predicted_genes\nprobe_dir = $probe_dir\noutfile = $outfile\nlogfile = $logfile\n\n";

my @gene_ids;

#The user may test a single gene or get all of them according to certain options
if ($ensembl_gene_id){
  my @ids;
  push (@ids, $ensembl_gene_id);
  my $gene_id_ref = &getGeneIds ('-dbh'=>$alexa_dbh, '-ensembl_g_ids'=>\@ids);
  my $gene_id = $gene_id_ref->{$ensembl_gene_id}->{alexa_gene_id};
  push (@gene_ids, $gene_id);

}elsif ($all_genes eq "yes"){

  if ($allow_predicted_genes eq "yes"){
    @gene_ids = @{&getAllGenes ('-dbh'=>$alexa_dbh, '-gene_type'=>'Non-pseudo')};
    my $gene_count = @gene_ids;
    print BLUE, "\nFound $gene_count genes that meet the criteria: 'Non-pseudo'\n\n", RESET;
    print LOG "\nFound $gene_count genes that meet the criteria: 'Non-pseudo'\n\n";

  }else{
    @gene_ids = @{&getAllGenes ('-dbh'=>$alexa_dbh, '-gene_type'=>'Non-pseudo', '-evidence'=>"Known Gene")};
    my $gene_count = @gene_ids;
    print BLUE, "\nFound $gene_count genes that meet the criteria: 'Non-pseudo' and 'Known Gene'\n\n", RESET;
    print LOG "\nFound $gene_count genes that meet the criteria: 'Non-pseudo' and 'Known Gene'\n\n";
  }

}else{
  print RED, "\nMust select either a single ensembl gene (--ensembl_gene_id=ENSG00000000003), or all genes option (--all_genes=yes)\n\n", RESET;
  close (LOG);
  $alexa_dbh->disconnect();
  exit();
}

my $gene_count = 0;
my $total_successful_probes = 0;
my $total_possible_probes = 0;

#Open the probe output file
print BLUE, "\nAll data will be written to $outfile\n\n", RESET;
print LOG "\nAll data will be written to $outfile\n\n";
open (OUTFILE, ">$outfile") || die "\nCould not open $outfile";

#Note: these probes only involve a single exon so Exon2_ID='na'
#The probe type will be Inton-Exon or Exon-Intron
print OUTFILE "Probe_Count\tProbeSet_ID\tGene_ID\tSequence\tProbe_length\tProbe_Tm\tProbe_Type\tExon1_IDs\tUnit1_start\tUnit1_end\tExon2_IDs\tUnit2_start\tUnit2_end\tmasked_bases\n";

#Get the gene sequence and other gene info for all genes
print BLUE, "\nGetting gene sequence data", RESET;
print LOG "\nGetting gene sequence data";
my $genes_ref = &getGeneInfo ('-dbh'=>$alexa_dbh, '-gene_ids'=>\@gene_ids,'-sequence'=>"yes");

#Get the complete masked sequence for all genes
my $masked_genes_ref;
unless ($ignore_masking eq "yes"){
  print BLUE, "\nGetting masked gene sequence data", RESET;
  print LOG "\nGetting masked gene sequence data";
  $masked_genes_ref = &getMaskedGene ('-dbh'=>$alexa_dbh, '-gene_ids'=>\@gene_ids);
}

#Get the exons for all genes
print BLUE, "\nGetting exon coordinate data", RESET;
print LOG "\nGetting exon coordinate data";
my $gene_exons_ref = &getExons ('-dbh'=>$alexa_dbh, '-gene_ids'=>\@gene_ids, '-sequence'=>"yes");

#Get the total theoretical probes possible for all genes
print BLUE, "\nGetting theoretical probe counts data", RESET;
print LOG "\nGetting theoretical probe counts data";
my $probe_counts_ref = &junctionProbeCombinations('-dbh'=>$alexa_dbh, '-gene_ids'=>\@gene_ids);

#Process genes
foreach my $gene_id (@gene_ids){
  $gene_count++;

  #Keep track of exons, successful probes and unsuccessful probes for this gene
  my $successful_probes = 0;

  #Get the start and end coordinates of the entire gene
  my $gene_start = $genes_ref->{$gene_id}->{gene_start};
  my $gene_end = $genes_ref->{$gene_id}->{gene_end};

  print CYAN, "\n\n\n**************************************************************************************************************", RESET;
  print CYAN, "\nGENE: $gene_count\tALEXA: $gene_id\tENSG: $genes_ref->{$gene_id}->{ensembl_g_id}\tGene Coords: ($gene_start - $gene_end)", RESET;
  print LOG "\n\n\n**************************************************************************************************************";
  print LOG "\nGENE: $gene_count\tALEXA: $gene_id\tENSG: $genes_ref->{$gene_id}->{ensembl_g_id}\tGene Coords: ($gene_start - $gene_end)";

  my $gene_seq = $genes_ref->{$gene_id}->{sequence};

  my $maskedGeneSeq;
  if ($ignore_masking eq "yes"){
    $maskedGeneSeq = $gene_seq;
  }else{
    $maskedGeneSeq = $masked_genes_ref->{$gene_id}->{sequence};
  }

  #1.) Get all exons for this gene
  my $exons_ref = $gene_exons_ref->{$gene_id}->{exons};
  my $exon_count = keys %{$exons_ref};

  #2.) Create a hash to track which exons correspond to which exons
  my %junction_maps_5p;
  my %junction_maps_3p;
  foreach my $exon_id (sort keys %{$exons_ref}){
    my $start = $exons_ref->{$exon_id}->{exon_start};
    my $end = $exons_ref->{$exon_id}->{exon_end};

    #Exon start positions (5p intron-exon junctions)
    if ($junction_maps_5p{$start}{exon_ids}){
      my @tmp = @{$junction_maps_5p{$start}{exon_ids}};
      push (@tmp, $exon_id);
      $junction_maps_5p{$start}{exon_ids} = \@tmp;
    }else{
      my @tmp;
      push (@tmp, $exon_id);
      $junction_maps_5p{$start}{exon_ids} = \@tmp;
    }
    #Exon end positions (3p exon-intron junctions)
    if ($junction_maps_3p{$end}{exon_ids}){
      my @tmp = @{$junction_maps_3p{$end}{exon_ids}};
      push (@tmp, $exon_id);
      $junction_maps_3p{$end}{exon_ids} = \@tmp;
    }else{
      my @tmp;
      push (@tmp, $exon_id);
      $junction_maps_3p{$end}{exon_ids} = \@tmp;
    }
  }

  #3.) Created a array of exons sorted by the position at which they start
  my @exon_array;
  foreach my $exon_id (sort {$exons_ref->{$a}->{exon_start} <=> $exons_ref->{$b}->{exon_start}} keys %{$exons_ref}){
    push (@exon_array, $exon_id);
  }

  #If the gene has only one exon - skip
  if ($exon_count == 1){
    print CYAN, "\n\tGene has only a single exon - skipping", RESET;
    next();
  }

  #4.) Go through each exon sequentially and get the exon-intron junction probes
  my %junctions_5p;  #Used to keep track of the 5 prime exon ends targeted
  my %junctions_3p;  #Used to keep track of the 3 prime exon ends targeted

  #PROCESS EXONS
  for (my $i = 0; $i < $exon_count; $i++){

    my $exon_id = $exon_array[$i];
    if ($verbose eq "yes"){
      print YELLOW, "\n\nProcess EXON: $exon_id\tSTART: $exons_ref->{$exon_id}->{exon_start}\tEND: $exons_ref->{$exon_id}->{exon_end}", RESET;
    }
    print LOG "\n\nProcess EXON: $exon_id\tSTART: $exons_ref->{$exon_id}->{exon_start}\tEND: $exons_ref->{$exon_id}->{exon_end}";

    my $exon_seq = $exons_ref->{$exon_id}->{sequence};

    #If the exon being considered is to short to allow for the specified probe length, skip it
    my $exon_length = length($exon_seq);
    if ($exon_length < (($target_length+$max_length_variance)/2)){
      if ($verbose eq "yes"){
	print YELLOW, "\n\t\tExon: $exon_id  Exon is too short ($exon_length bp) to allow a probe of the specified length", RESET;
      }
      print LOG "\n\t\tExon: $exon_id  Exon is too short ($exon_length bp) to allow a probe of the specified length";
      next();
    }

    #Define the exon sequence
    my $gene_seq = $genes_ref->{$gene_id}->{sequence};
    my $gene_length = length($gene_seq);
    my $exon_start = $exons_ref->{$exon_id}->{exon_start};
    my $exon_end = $exons_ref->{$exon_id}->{exon_end};

    #Loop through all possible probe lengths as specified by the user
    my %junction_probes_5p; #Store probes of varying length for a single Intron-Exon junction
    my %junction_probes_3p; #Store probes of varying length for a single Exon-Intron junction
    my $junction_probe_5p_count = 0;
    my $junction_probe_3p_count = 0;

    for (my $j = $target_length-$max_length_variance; $j <= $target_length+$max_length_variance; $j+=2){

      #Probe length is altered in each iteration, but the probe sequence is alway centered on the junction
      my $probe_length = $j;

      ###################################################
      #4-A.) Get the 5-PRIME INTRON-EXON probe sequence #
      ###################################################

      #Avoid processing the first exon (as there is no intron sequence defined upstream of it)
      unless ($exon_start == $gene_start){

	my $intron_start_5p = ($exon_start - ($probe_length/2))-1;
	my $intron_end_5p = $exon_start-1;
	my $intron_seq_5p = substr ($gene_seq, $intron_start_5p, $probe_length);
	my $probe_5p_length = length($intron_seq_5p);
	my $test_seq_5p = $intron_seq_5p;

	#If the proposed 5-prime intron start is before the beginning of the gene, skip it (always the case for the first exon)
	if ($intron_start_5p <= 0){
	  if ($verbose eq "yes"){
	    print YELLOW, "\n\t\tExon: $exon_id  5-PRIME  Not enough intron sequence 5 prime of this exon", RESET;
	  }
	  print LOG "\n\t\tExon: $exon_id  5-PRIME  Not enough intron sequence 5 prime of this exon";
	  $intron_seq_5p = '';
	}

	#NOTE: Some exons actually contain N's from the underlying genomic sequence in ensembl!
	#For simplicity, probes that incorporate these unknown bases should be skipped!
	#Check for presence of genomic N's and other non-valid letters such as Ambiguiety codes
	if($test_seq_5p =~ /[^ATCG]/){
	  if ($verbose eq "yes"){
	    print YELLOW, "\n\t\tExon: $exon_id 5-PRIME  Ensembl region for this probe contains N's or other invalid bases!", RESET;
	  }
	  print LOG "\n\t\tExon: $exon_id 5-PRIME  Ensembl region for this probe contains N's or other invalid bases!";
	  $intron_seq_5p = '';
	}

	#Check for presence of excessive RepeatMasked bases in this region
	my $masked_intron_seq_5p = substr ($maskedGeneSeq, $intron_start_5p, $probe_length);
	my @masked_n_count_5p = $masked_intron_seq_5p =~ m/N/g;
	my $masked_n_count_5p = @masked_n_count_5p;
	
	#If too many bases are repeat masked, reject this probe
	my $allowed_masked_bases = ($probe_length/4);  #If more than 1/4 of probe is masked, it will be rejected
	if ($masked_n_count_5p > $allowed_masked_bases){
	  #If this probe hasn't already been disqualified, print out the excessive masking problem
	  if ($intron_seq_5p){
	    if ($verbose eq "yes"){
	      print YELLOW, "\n\t\tExon: $exon_id  5-PRIME  Too many Repeat-Masked bases", RESET;
	      print YELLOW, "\n\t\t\tPROBE:  $intron_seq_5p\n\tMASKED: $masked_intron_seq_5p", RESET;
	    }
	    print LOG "\n\t\tExon: $exon_id  5-PRIME  Too many Repeat-Masked bases";
	    print LOG "\n\t\t\tPROBE:  $intron_seq_5p\n\tMASKED: $masked_intron_seq_5p";
	  }
	  $intron_seq_5p = '';
	}

	#Keep track of the 5-prime start position used to avoid repeats
	if ($junctions_5p{$intron_start_5p}){
	  if ($verbose eq "yes"){
	    print YELLOW, "\n\t\tExon: $exon_id  5-PRIME  Already have this intron-exon junction from a previous exon", RESET;
	  }
	  print LOG "\n\t\tExon: $exon_id  5-PRIME  Already have this intron-exon junction from a previous exon";
	}elsif($intron_seq_5p){
	  #Add successful intron-exon probe to the list for this junction
	  $junctions_5p{$intron_start_5p}{junk}='';

	  my @unit2_exon_ids = @{$junction_maps_5p{$exon_start}{exon_ids}};
	  my $exon_start_pos = $exon_start;
	  my $probe_end = ($exon_start+($probe_length/2));

	  #Sanity check
	  unless (length($intron_seq_5p) == $probe_length){
	    print RED, "\nExon: $exon_id  5-PRIME  Incorrect probe length\n\n", RESET;
	    close (LOG);
	    $alexa_dbh->disconnect();
	    exit();
	  }

	  #Store this probe Intron-Exon probe
	  $junction_probe_5p_count++;

	  #If this probe passes all the simple filters here, calculate its Tm and add it to list of potential list of probes for this junction
	  my $temp_k_5p = &tmCalc('-sequence'=>$intron_seq_5p, '-silent'=>1);
	  my $Tm_celsius_5p = &tmConverter('-tm'=>$temp_k_5p, '-scale'=>'Kelvin');

	  $junction_probes_5p{$junction_probe_5p_count}{sequence} = $intron_seq_5p;
	  $junction_probes_5p{$junction_probe_5p_count}{probe_seq_length} = length($intron_seq_5p);
	  $junction_probes_5p{$junction_probe_5p_count}{length} = $probe_length;
	  $junction_probes_5p{$junction_probe_5p_count}{tm} = $Tm_celsius_5p;
	  $junction_probes_5p{$junction_probe_5p_count}{exon_ids} = \@unit2_exon_ids;
	  $junction_probes_5p{$junction_probe_5p_count}{exon_start} = $exon_start;
	  $junction_probes_5p{$junction_probe_5p_count}{exon_end} = $exon_end;
	  $junction_probes_5p{$junction_probe_5p_count}{unit1_start} = $intron_start_5p;
	  $junction_probes_5p{$junction_probe_5p_count}{unit1_end} = $intron_end_5p;
	  $junction_probes_5p{$junction_probe_5p_count}{unit2_start} = $exon_start_pos;
	  $junction_probes_5p{$junction_probe_5p_count}{unit2_end} = $probe_end;
	  $junction_probes_5p{$junction_probe_5p_count}{masked_bases} = $masked_n_count_5p;
	}
      }

      #####################################################
      #4-B.) Get the 3-PRIME (EXON-INTRON) probe sequence #
      #####################################################

      #Avoid processing the last exon (as there is no intron sequence defined downstream of it)
      unless ($exon_end == $gene_end){

	my $exon_start_3p = ($exon_end - ($probe_length/2)); #Unit1_start
	my $intron_end_3p = $exon_start_3p+$probe_length+1;      #Unit2_end
	my $intron_seq_3p = substr ($gene_seq, $exon_start_3p, $probe_length);
	my $probe_3p_length = length($intron_seq_3p);
	my $test_seq_3p = $intron_seq_3p;

	#If the proposed 3-prime intron end is past the end of the gene, skip it (always the case for the last exon)
	if ($intron_end_3p > $gene_length){
	  if ($verbose eq "yes"){
	    print YELLOW, "\n\t\tExon: $exon_id  3-PRIME  Not enough intron sequence 3 prime of this exon", RESET;
	  }
	  print LOG "\n\t\tExon: $exon_id  3-PRIME  Not enough intron sequence 3 prime of this exon";
	  $intron_seq_3p = '';
	}

	#NOTE: Some exons actually contain N's from the underlying genomic sequence in ensembl!
	#For simplicity, probes that incorporate these unknown bases should be skipped!
	#Check for presence of genomic N's and other non-valid letters such as Ambiguiety codes
	if($test_seq_3p =~ /[^ATCG]/){
	  if ($verbose eq "yes"){
	    print YELLOW, "\n\t\tExon: $exon_id 3-PRIME  Ensembl region for this probe contains N's or other invalid bases!", RESET;
	  }
	  print LOG "\n\t\tExon: $exon_id 3-PRIME  Ensembl region for this probe contains N's or other invalid bases!";
	  $intron_seq_3p = '';
	}

	#Check for presence of excessive RepeatMasked bases in this region
	my $masked_intron_seq_3p = substr ($maskedGeneSeq, $exon_start_3p, $probe_length);
	my @masked_n_count_3p = $masked_intron_seq_3p =~ m/N/g;
	my $masked_n_count_3p = @masked_n_count_3p;
	#If too many bases are repeat masked, reject this probe
	my $allowed_masked_bases = ($probe_length/4);  #If more than 1/4 of probe is masked, it will be rejected
	if ($masked_n_count_3p > $allowed_masked_bases){
	  #If this probe hasn't already been disqualified, print out the excessive masking problem
	  if ($intron_seq_3p){
	    if ($verbose eq "yes"){
	      print YELLOW, "\n\t\tExon: $exon_id  3-PRIME  Too many Repeat-Masked bases", RESET;
	      print YELLOW, "\n\t\t\tPROBE:  $intron_seq_3p\n\t\tMASKED: $masked_intron_seq_3p", RESET;
	    }
	    print LOG "\n\t\tExon: $exon_id  3-PRIME  Too many Repeat-Masked bases";
	    print LOG "\n\t\t\tPROBE:  $intron_seq_3p\n\t\tMASKED: $masked_intron_seq_3p";
	  }
	  $intron_seq_3p = '';
	}
	
	#Keep track of the 5-prime and 3-prime start positions used to avoid repeats
	if ($junctions_3p{$exon_start_3p}){
	  if ($verbose eq "yes"){
	    print YELLOW, "\n\t\tExon: $exon_id  3-PRIME  Already have this intron-exon junction from a previous exon", RESET;
	  }
	  print LOG "\n\t\tExon: $exon_id  3-PRIME  Already have this intron-exon junction from a previous exon";

	}elsif($intron_seq_3p){
	  #Add successful intron-exon probe to the list for this junction
	  $junctions_3p{$exon_start_3p}{junk}='';

	  my @unit1_exon_ids = @{$junction_maps_3p{$exon_end}{exon_ids}};
	  my $exon_end_3p = $exon_end;     #Unit1_end
	  my $intron_start_3p = $exon_end+1; #Unit2_start

	  #Sanity check
	  unless (length($intron_seq_3p) == $probe_length){
	    print RED, "\nExon: $exon_id  3-PRIME  Incorrect probe length\n\n", RESET;
	    close (LOG);
	    $alexa_dbh->disconnect();
	    exit();
	  }

	  #Store this probe Exon-Intron probe
	  $junction_probe_3p_count++;

	  #If this probe passes all the simple filters here, calculate its Tm and add it to list of potential list of probes for this junction
	  my $temp_k_3p = &tmCalc('-sequence'=>$intron_seq_3p, '-silent'=>1);
	  my $Tm_celsius_3p = &tmConverter('-tm'=>$temp_k_3p, '-scale'=>'Kelvin');

	  $junction_probes_3p{$junction_probe_3p_count}{sequence} = $intron_seq_3p;
	  $junction_probes_3p{$junction_probe_3p_count}{probe_seq_length} = length($intron_seq_3p);
	  $junction_probes_3p{$junction_probe_3p_count}{length} = $probe_length;
	  $junction_probes_3p{$junction_probe_3p_count}{tm} = $Tm_celsius_3p;
	  $junction_probes_3p{$junction_probe_3p_count}{exon_ids} = \@unit1_exon_ids;
	  $junction_probes_3p{$junction_probe_3p_count}{exon_start} = $exon_start;
	  $junction_probes_3p{$junction_probe_3p_count}{exon_end} = $exon_end;
	  $junction_probes_3p{$junction_probe_3p_count}{unit1_start} = $exon_start_3p;
	  $junction_probes_3p{$junction_probe_3p_count}{unit1_end} = $exon_end_3p;
	  $junction_probes_3p{$junction_probe_3p_count}{unit2_start} = $intron_start_3p;
	  $junction_probes_3p{$junction_probe_3p_count}{unit2_end} = $intron_end_3p;
	  $junction_probes_3p{$junction_probe_3p_count}{masked_bases} = $masked_n_count_3p;

	}
      }

    }#Probe Length variance loop

    #5.) Now that probes have been generated for all possible lengths of probe for both ends of this exon, rank them according to Tm and select the desired number

    #Intron-Exon
    #First make sure the desired number of probes was found
    my $junction_5p_probes_found = keys %junction_probes_5p;
    if ($junction_5p_probes_found >= $probes_per_junction){
      $current_probeset_id++;
      #Calculate absolute difference from target
      foreach my $jp_count (keys %junction_probes_5p){
	$junction_probes_5p{$jp_count}{abs_target_tm_diff} = abs($junction_probes_5p{$jp_count}{tm} - $target_tm);
      }

      my $probes_selected = 0;
      foreach my $jp_count (sort {$junction_probes_5p{$a}->{abs_target_tm_diff} <=> $junction_probes_5p{$b}->{abs_target_tm_diff}} keys %junction_probes_5p){
	#Print probe info to Output probe file
	$probes_selected++;

	if ($probes_selected > $probes_per_junction){
	  last();
	}
	my $tm_rounded = sprintf("%.3f", $junction_probes_5p{$jp_count}{tm});

	#Verbose Printing Section - Helpful for debugging ...
	if ($verbose eq "yes"){
	  print YELLOW, "\n\n\tINTRON-EXON Probe $probes_selected", RESET;
	  print YELLOW, "\n\t\tUNIT1: Start=$junction_probes_5p{$jp_count}{unit1_start}\tEnd=$junction_probes_5p{$jp_count}{unit1_end}", RESET;
	  print YELLOW, "\n\t\tUNIT2: Start=$junction_probes_5p{$jp_count}{unit2_start}\tEnd=$junction_probes_5p{$jp_count}{unit2_end}", RESET;
	  print YELLOW, "\n\t\tPROBE: $junction_probes_5p{$jp_count}{sequence} ($junction_probes_5p{$jp_count}{probe_seq_length}) (Tm = $tm_rounded)", RESET;
	}

	#Probe_Count,ProbeSet_ID,Gene_ID,Sequence,Probe_length,Probe_Tm,Probe_Type,Exon1_IDs (na),Unit1_start,Unit1_end,Exon2_IDs,Unit2_start,Unit2_end,masked_bases
	$current_probe_id++;
	$successful_probes++;
	$total_successful_probes++;
	
	my $probe_type = "Intron-Exon";
	
	print OUTFILE "$current_probe_id\t$current_probeset_id\t$gene_id\t$junction_probes_5p{$jp_count}{sequence}\t$junction_probes_5p{$jp_count}{length}\t$tm_rounded\t$probe_type\tna\t$junction_probes_5p{$jp_count}{unit1_start}\t$junction_probes_5p{$jp_count}{unit1_end}\t@{$junction_probes_5p{$jp_count}{exon_ids}}\t$junction_probes_5p{$jp_count}{unit2_start}\t$junction_probes_5p{$jp_count}{unit2_end}\t$junction_probes_5p{$jp_count}{masked_bases}\n";
      }#Print probes for this junction loop
    }else{
      if ($verbose eq "yes"){
	print YELLOW, "\n\n\tINTRON-EXON Probe", RESET;
	print YELLOW, "\n\t\tCould not find the desired number of 5-prime junction probes for exon: $exon_id", RESET;
      }
      print LOG "\n\n\tINTRON-EXON Probe";
      print LOG "\n\t\tCould not find the desired number of 5-prime junction probes for exon: $exon_id";
    }

    #Exon-Intron
    #First make sure the desired number of probes was found
    my $junction_3p_probes_found = keys %junction_probes_3p;
    if ($junction_3p_probes_found >= $probes_per_junction){
      $current_probeset_id++;
      #Calculate absolute difference from target
      foreach my $jp_count (keys %junction_probes_3p){
	$junction_probes_3p{$jp_count}{abs_target_tm_diff} = abs($junction_probes_3p{$jp_count}{tm} - $target_tm);
      }

      my $probes_selected = 0;
      foreach my $jp_count (sort {$junction_probes_3p{$a}->{abs_target_tm_diff} <=> $junction_probes_3p{$b}->{abs_target_tm_diff}} keys %junction_probes_3p){
	#Print probe info to Output probe file
	$probes_selected++;

	if ($probes_selected > $probes_per_junction){
	  last();
	}
	my $tm_rounded = sprintf("%.3f", $junction_probes_3p{$jp_count}{tm});

	#Verbose Printing Section - Helpful for debugging ...
	if ($verbose eq "yes"){
	  print YELLOW, "\n\n\tEXON-INTRON Probe $probes_selected", RESET;
	  print YELLOW, "\n\t\tUNIT1: Start=$junction_probes_3p{$jp_count}{unit1_start}\tEnd=$junction_probes_3p{$jp_count}{unit1_end}", RESET;
	  print YELLOW, "\n\t\tUNIT2: Start=$junction_probes_3p{$jp_count}{unit2_start}\tEnd=$junction_probes_3p{$jp_count}{unit2_end}", RESET;
	  print YELLOW, "\n\t\tPROBE: $junction_probes_3p{$jp_count}{sequence} ($junction_probes_3p{$jp_count}{probe_seq_length}) (Tm = $tm_rounded)", RESET;
	}

	#Probe_Count,ProbeSet_ID,Gene_ID,Sequence,Probe_length,Probe_Tm,Probe_Type,Exon1_IDs,Unit1_start,Unit1_end,Exon2_IDs (na),Unit2_start,Unit2_end,masked_bases
	$current_probe_id++;
	$successful_probes++;
	$total_successful_probes++;
	
	my $probe_type = "Exon-Intron";
	
	print OUTFILE "$current_probe_id\t$current_probeset_id\t$gene_id\t$junction_probes_3p{$jp_count}{sequence}\t$junction_probes_3p{$jp_count}{length}\t$tm_rounded\t$probe_type\t@{$junction_probes_3p{$jp_count}{exon_ids}}\t$junction_probes_3p{$jp_count}{unit1_start}\t$junction_probes_3p{$jp_count}{unit1_end}\tna\t$junction_probes_3p{$jp_count}{unit2_start}\t$junction_probes_3p{$jp_count}{unit2_end}\t$junction_probes_3p{$jp_count}{masked_bases}\n";
      }#Print probes for this junction loop
    }else{
      if ($verbose eq "yes"){
	print YELLOW, "\n\n\tEXON-INTRON Probe", RESET;
	print YELLOW, "\n\t\tCould not find the desired number of 3-prime junction probes for exon: $exon_id", RESET;
      }
      print LOG "\n\n\tEXON-INTRON Probe";
      print LOG "\n\t\tCould not find the desired number of 3-prime junction probes for exon: $exon_id";
    }

  }#Process Exons Loop

  #Calculate the total theoretical probes possible for this gene
  my $possible_probes = ($probe_counts_ref->{$gene_id}->{intron_exon})*($probes_per_junction);
  $total_possible_probes += $possible_probes;

  print CYAN, "\n\nSUMMARY for Gene ID: $gene_id", RESET;
  print CYAN, "\nNumber Exons = $exon_count\tPossible Exon-Intron Junction Probes = $possible_probes\tSuccessful Probes = $successful_probes", RESET;
  print LOG "\n\nSUMMARY for Gene ID: $gene_id";
  print LOG "\nNumber Exons = $exon_count\tPossible Exon-Intron Junction Probes = $possible_probes\tSuccessful Probes = $successful_probes";

}#Gene Loop

print CYAN, "\n\nFinal Summary of all intron junction probes designed", RESET;
print CYAN, "\nTotal Possible Probes (where $probes_per_junction probes are desired for each junction) = $total_possible_probes\nTotal Successful Probes = $total_successful_probes\n\n", RESET;
print LOG "\n\nFinal Summary of all intron junction probes designed";
print LOG "\nTotal Possible Probes (where $probes_per_junction probes are desired for each junction) = $total_possible_probes\nTotal Successful Probes = $total_successful_probes\n\n";

close (OUTFILE);
close (LOG);

#Close database connection
$alexa_dbh->disconnect();

exit();
