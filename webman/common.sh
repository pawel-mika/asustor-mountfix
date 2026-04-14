#!/bin/sh

is_ssd() {
    local md_device=$1  # np. md2
    # get the first slave device of the md device (e.g., md2 -> sda, sdb, etc.) and check if it's an SSD or HDD
    local first_slave=$(ls /sys/block/$md_device/slaves | head -n 1)
    
    if [ -z "$first_slave" ]; then
        return 1 # no slave found, treat as HDD by default
    fi

    # check if the first slave device is rotational or not (0 = SSD, 1 = HDD)
    local rotational=$(cat /sys/block/$first_slave/queue/rotational)
    
    if [ "$rotational" -eq 0 ]; then
        return 0 # SSD
    else
        return 1 # HDD
    fi
}

get_volume_rotational() {
    local target=$1 # It can be /volume1 or /dev/md1
    local dev_name=""

    # 1. Check if a path was provided (starts with /volume)
    if echo "$target" | grep -q "^/volume"; then
        # Extract the device associated with this mount point
        # Use awk to precisely extract /dev/mdX
        dev_name=$(mount | grep "on $target " | awk '{print $1}' | cut -d'/' -f3)
    else
        # If mdX or /dev/mdX was provided directly
        dev_name=$(echo "$target" | sed 's|/dev/||')
    fi

    # 2. If no device was found, return error (1 as HDD)
    if [ -z "$dev_name" ]; then
        echo "1"
        return
    fi

    # 3. Find the first physical disk in RAID
    local first_slave=$(ls "/sys/block/$dev_name/slaves" 2>/dev/null | head -n 1)

    if [ -z "$first_slave" ]; then
        # If it's not RAID, but a regular disk (e.g., sda)
        if [ -e "/sys/block/$dev_name/queue/rotational" ]; then
            cat "/sys/block/$dev_name/queue/rotational"
        else
            echo "1"
        fi
    else
        # If it's RAID, check the slave
        cat "/sys/block/$first_slave/queue/rotational"
    fi
}