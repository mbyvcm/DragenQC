#!/bin/bash
set -eo pipefail

# Description:
# Author:
# Mode:
# Usage:

#------------------------#
# Define Input Variables # 
#------------------------#

version="0.0.1"

# run directory location
sourceDir=$1

echo "$sourceDir"

# Illumina run directory name 
seqId=$(basename "$sourceDir")

# instrument name
instrument=$(echo $sourceDir | cut -d"/" -f2) 

# define base path of local NVMe outputs
fastqDirTemp=/staging/data/fastq
resultsDirTemp=/staging/data/results

# create temp directories in staging
mkdir -p $fastqDirTemp
mkdir -p $resultsDirTemp

#-----------------#
# Extract Quality #
#-----------------#

# collect interop data
summary=$(/data/apps/interop-distros/InterOp-1.0.25-Linux-GNU-4.8.2/bin/summary --level=3 --csv=1 "$sourceDir")

# extract fields
yieldGb=$(echo "$summary" | grep ^Total | cut -d, -f2)
q30Pct=$(echo "$summary" | grep ^Total | cut -d, -f7)
avgDensity=$(echo "$summary" | grep -A999 "^Level" | grep ^[[:space:]]*[0-9] | awk -F',| ' '{print $1"\t"$4}' | sort | uniq | awk -F'\t' '{total += $2; count++} END {print total/count}')
avgPf=$(echo "$summary" | grep -A999 "^Level" |grep ^[[:space:]]*[0-9] | awk -F',| ' '{print $1"\t"$7}' | sort | uniq | awk -F'\t' '{total += $2; count++} END {print total/count}')
totalReads=$(echo "$summary" | grep -A999 "^Level" | grep ^[[:space:]]*[0-9] | awk -F',| ' '{print $1"\t"$19}' | sort | uniq | awk -F'\t' '{total += $2} END {print total}')

#----------------------#
# Generate FASTQ Files #
#----------------------#

echo "Staring Demultiplex"

# convert BCLs to FASTQ using DRAGEN
dragen \
    --bcl-conversion-only true \
    --bcl-input-directory "$sourceDir" \
    --output-directory $fastqDirTemp/$seqId

# copy files to keep to long-term storage
fastqDirTempRun="$fastqDirTemp"/"$seqId"/
cd $fastqDirTempRun
cp "$sourceDir"/SampleSheet.csv .
cp "$sourceDir"/?unParameters.xml RunParameters.xml
cp "$sourceDir"/RunInfo.xml .
cp -R "$sourceDir"/InterOp .

# print metrics headers to file
if [ -e "$seqId"_metrics.txt ]; then
    rm "$seqId"_metrics.txt
fi

# print metrics to file
echo -e "Run\tTotalGb\tQ30\tAvgDensity\tAvgPF\tTotalMReads" > "$seqId"_metrics.txt
echo -e "$(basename $sourceDir)\t$yieldGb\t$q30Pct\t$avgDensity\t$avgPf\t$totalReads" >> "$seqId"_metrics.txt


#---------------------#
# Make Variable Files #
#---------------------#

echo "making variables files"

java -jar /data/apps/MakeVariableFiles/MakeVariableFiles-2.1.0.jar \
    SampleSheet.csv \
    RunParameters.xml

# move FASTQ & variable files into project folders
for variableFile in $(ls *.variables);do

    # reset variables if defined
    unset sampleId seqId worklistId pipelineVersion pipelineName panel owner workflow

    # load variables into local scope
    . "$variableFile"

    # make sample folder
    mkdir -p ./Data/$panel/"$sampleId"
    mv "$variableFile" ./Data/"$panel"/"$sampleId"
    mv "$sampleId"_S*.fastq.gz ./Data/"$panel"/"$sampleId"

done

# trigger pipeline if defined in variables file
for sampleDir in ./Data/*/*;do

    # reset variables if defined
    unset sampleId seqId worklistId pipelineVersion pipelineName panel owner workflow

    cd $sampleDir
    . *.variables

    if [ -z $piplineName ]; then
        echo "$sampleId --> running pipeline: $pipelineName-$pipelineVersion"
        # run pipeline save data to /staging/data/results/
        bash /data/pipelines/$pipelineName/"$pipelineName"-"$pipelineVersion"/"$pipelineName".sh "$sampleDir" 
    else
        echo "$sampleId --> DEMULTIPLEX ONLY"
    fi

    cd $fastqDirTempRun

done


# all DRAGEN analyses finised
# move FASTQ
cp -r "$fastqDirTempRun" /mnt/novaseq-archive-fastq

# move results
cp -r "$resultsDirTempRun" /mnt/novaseq-results

# write dragen-complete file to raw (flag for moving by host cron)
touch $sourceDir/dragen-complete
