#!/usr/bin/env bash
# The MIT License (MIT)
#
# Copyright (c) 2021-2024 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
set -e
set -o pipefail

repo=$1
pos=$2
total=$3

start=$(date +%s%N)

project=${TARGET}/github/${repo}

logs=${TARGET}/temp/jpeek-logs/${repo}

if [ -e "${logs}" ]; then
    echo "Repo ${repo} already analyzed by jPeek"
    exit
fi

mkdir -p "${logs}"

build() {
    if [ -e "${project}/gradlew" ]; then
        echo "Building ${repo} (${pos}/${total}) with Gradlew..."
        if ! timeout 1h "${project}/gradlew" classes -q -p "${project}" > "${logs}/gradlew.log" 2>&1; then
            echo "Failed to compile ${repo} using Gradlew$("${LOCAL}/help/tdiff.sh" "${start}")"
            exit
        fi
        echo "Сompiled ${repo} using Gradlew$("${LOCAL}/help/tdiff.sh" "${start}")"
    elif [ -e "${project}/build.gradle" ]; then
        echo "Building ${repo} (${pos}/${total}) with Gradle..."
        echo "apply plugin: 'java'" >> "${project}/build.gradle"
        if ! timeout 1h gradle classes -q -p "${project}" > "${logs}/gradle.log" 2>&1; then
            echo "Failed to compile ${repo} using Gradle$("${LOCAL}/help/tdiff.sh" "${start}")"
            exit
        fi
        echo "Сompiled ${repo} using Gradle$("${LOCAL}/help/tdiff.sh" "${start}")"
    elif [ -e "${project}/pom.xml" ]; then
        echo "Building ${repo} (${pos}/${total}) with Maven..."
        if ! timeout 1h mvn compile -quiet -DskipTests -f "${project}" -U > "${logs}/maven.log" 2>&1; then
            echo "Failed to compile ${repo} using Maven$("${LOCAL}/help/tdiff.sh" "${start}")"
            exit
        fi
        echo "Сompiled ${repo} using Maven$("${LOCAL}/help/tdiff.sh" "${start}")"
    else
        echo "Could not build classes in ${repo} (${pos}/${total}) (neither Maven nor Gradle project)"
        exit
    fi
}

collect() {
    timeout 1h java -jar "${JPEEK}" --overwrite --include-ctors --include-static-methods \
        --include-private-methods --sources "${project}" \
        --target "${TARGET}/temp/jpeek/all/${repo}" > "${logs}/jpeek-all.log" 2>&1
    timeout 1h java -jar "${JPEEK}" --overwrite --sources "${project}" \
        --target "${TARGET}/temp/jpeek/cvc/${repo}" > "${logs}/jpeek-cvc.log" 2>&1
}

declare -i re=0
until build; do
    re=$((re+1))
    echo "Retry #${re} for ${repo} (${pos}/${total})..."
done

start=$(date +%s%N)

if ! collect; then
    echo "Failed to calculate jpeek metrics in ${repo} (${pos}/${total}) due to jpeek.jar error$("${LOCAL}/help/tdiff.sh" "${start}")"
    exit
fi

accept=".*[^index|matrix|skeleton].xml"

values=${TARGET}/temp/jpeek-values/${repo}.txt
mkdir -p "$(dirname "${values}")"
echo > "${values}"
files=${TARGET}/temp/jpeek-files/${repo}.txt
mkdir -p "$(dirname "${files}")"
printf '' > "${files}"
for type in all cvc; do
    dir=${TARGET}/temp/jpeek/${type}/${repo}
    if [ ! -e "${dir}" ]; then
        echo "No files generated by jpeek in ${dir}"
        continue
    fi
    find "${dir}" -type f -maxdepth 1 -print | while IFS= read -r report; do
        if echo "${report}" | grep -q "${accept}"; then
            packages=$(xmlstarlet sel -t -v 'count(/metric/app/package/@id)' "${report}")
            name=$(xmlstarlet sel -t -v "/metric/title" "${report}")
            for ((i=1; i <= packages; i++)); do
                id=$(xmlstarlet sel -t -v "/metric/app/package[${i}]/@id" "${report}")
                package=$(echo "${id}" | tr '.' '/')
                classes=$(xmlstarlet sel -t -v "count(/metric/app/package[${i}]/class/@id)" "${report}")
                for ((j=1; j <= classes; j++)); do
                    class=$(xmlstarlet sel -t -v "/metric/app/package[${i}]/class[${j}]/@id" "${report}")
                    value=$(xmlstarlet sel -t -v "/metric/app/package[${i}]/class[${j}]/@value" "${report}")
                    if [ ! "${value}" = "NaN" ]; then
                        echo "${value}" >> "${values}"
                    fi
                    suffix=${name}
                    if [ ! "${type}" = "all" ]; then
                        suffix=${suffix}-${type}
                    fi
                    jfile=$(find "${project}" -type f -path "*${package}/${class}.java" -exec realpath --relative-to="${project}" {} \;)
                    echo "${jfile}" >> "${files}"
                    mfile=${TARGET}/measurements/${repo}/${jfile}.m.${suffix}
                    mkdir -p "$(dirname "${mfile}")"
                    echo "${value}" > "${mfile}"
                done
            done
        fi
    done
done

echo "Analyzed ${repo} through jPeek (${pos}/${total}), \
$(sort "${files}" | uniq | wc -l | xargs) classes, \
sum is $(awk '{ sum += $1 } END { print sum }' "${values}" | xargs)$("${LOCAL}/help/tdiff.sh" "${start}")"
