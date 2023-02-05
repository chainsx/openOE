#!/bin/bash

__usage="
Usage: gen_image [OPTIONS]
Generate rockchip bootable image.
The target compressed bootable images will be generated in the build/YYYY-MM-DD folder of the directory where the gen_image.sh script is located.

Options: 
  -n, --name IMAGE_NAME         The Rockchip image name to be built.
  -h, --help                    Show command help.
"

help()
{
    echo "$__usage"
    exit $1
}

source ./scripts/common.sh

default_param() {
    outputdir=${build_dir}/$(date +'%Y-%m-%d')
    name=openEuler-Rockchip-aarch64-alpha1
    boot_dir=$rootfs_dir/boot
    uboot_dir=${build_dir}/u-boot
    boot_mnt=${build_dir}/boot_tmp
    root_mnt=${build_dir}/root_tmp
}

parseargs()
{
    if [ "x$#" == "x0" ]; then
        return 0
    fi

    while [ "x$#" != "x0" ];
    do
        if [ "x$1" == "x-h" -o "x$1" == "x--help" ]; then
            return 1
        elif [ "x$1" == "x" ]; then
            shift
        elif [ "x$1" == "x-n" -o "x$1" == "x--name" ]; then
            name=`echo $2`
            shift
            shift
        else
            echo `date` - ERROR, UNKNOWN params "$@"
            return 2
        fi
    done
}

write_uboot() {
    if [[ -f $work_dir/config/u-boot/apply-u-boot/$PLATFORM.sh ]];then
        bash $work_dir/config/u-boot/apply-u-boot/$PLATFORM.sh ${loopX}
        echo "write uboot done."
    else
        echo "apply-u-boot script file check failed, please fix."
    exit 2
    fi
}

set_cmdline(){
    vmlinuz_name=$(ls $boot_dir | grep vmlinuz)
    dtb_name=$boot_dir/dtb/$BOOT_DTB_FILE
    echo "label openEuler
    kernel /${vmlinuz_name}
    initrd /initrd.img
    fdt /${dtb_name}
    append  root=UUID=${fstab_array[2]} $CMDLINE" > $1
}

make_img(){
    cd $build_dir
    device=""
    LOSETUP_D_IMG
    size=`du -sh --block-size=1MiB ${build_dir}/rootfs | cut -f 1 | xargs`
    size=$(($size+720))
    losetup -D
    img_file=${build_dir}/${name}.img
    dd if=/dev/zero of=${img_file} bs=1MiB count=$size status=progress && sync

    parted ${img_file} mklabel gpt mkpart primary fat32 32768s 524287s
    parted ${img_file} -s set 1 boot on
    parted ${img_file} mkpart primary ext4 524288s 100%

    device=`losetup -f --show -P ${img_file}`
    trap 'LOSETUP_D_IMG' EXIT
    kpartx -va ${device}
    loopX=${device##*\/}
    partprobe ${device}

    bootp=/dev/mapper/${loopX}p1
    rootp=/dev/mapper/${loopX}p2
    LOG "make image partitions done."
    
    mkfs.vfat -n boot ${bootp}
    mkfs.ext4 -L rootfs ${rootp}
    LOG "make filesystems done."
    mkdir -p ${root_mnt} ${boot_mnt}
    mount -t vfat -o uid=root,gid=root,umask=0000 ${bootp} ${boot_mnt}
    mount -t ext4 ${rootp} ${root_mnt}

    cp -rfp ${boot_dir}/* ${boot_mnt}
    cp -rfp ${boot_mnt}/dtb* ${boot_mnt}/dtb
    sync
    rm -rf ${boot_dir}/*

    rsync -avHAXq ${rootfs_dir}/* ${root_mnt}
    sync
    sleep 10
    LOG "copy openEuler-root done."

    fstab_array=("" "" "" "")
    for line in `blkid | grep /dev/mapper/${loopX}p`
    do
        partuuid=${line#*PARTUUID=\"}
        fstab_array[${line:$prefix_len:1}]=${partuuid%%\"*}
    done
    echo "PARTUUID=${fstab_array[2]}  / ext4    defaults,noatime 0 0" > ${rootfs_dir}/etc/fstab
    echo "PARTUUID=${fstab_array[1]}  /boot vfat    defaults,noatime 0 0" >> ${rootfs_dir}/etc/fstab

    mkdir -p ${boot_mnt}/extlinux
    set_cmdline ${boot_mnt}/extlinux/extlinux.conf

    umount $rootp
    umount $bootp
    umount ${rootfs_dir}
    umount ${boot_dir}

    write_uboot

    LOSETUP_D_IMG
    losetup -D
}

outputd(){
    cd $build_dir

    if [ -f $outputdir ];then
        img_name_check=$(ls $outputdir | grep $name)
        if [ "x$img_name_check" != "x" ]; then
            rm ${name}.img*
            rm ${name}.tar.gz*
        fi
    else
        mkdir -p $outputdir
    fi
    mv ${name}.img ${outputdir}
    LOG "xz openEuler image begin..."
    xz ${outputdir}/${name}.img
    if [ ! -f ${outputdir}/${name}.img.xz ]; then
        ERROR "xz openEuler image failed!"
        exit 2
    else
        LOG "xz openEuler image success."
    fi

    cd $outputdir
    sha256sum ${name}.img.xz >> ${name}.img.xz.sha256sum

    LOG "The target images are generated in the ${outputdir}."
}

set -e
default_param
parseargs "$@" || help $?
if [ ! -d ${log_dir} ];then mkdir -p ${log_dir}; fi

LOG "gen image..."
make_img
outputd
