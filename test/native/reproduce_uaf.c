#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>
#include "miniaudio_player.h"

int main(int argc, char **argv)
{
    if (argc < 2)
    {
        printf("Usage: %s <case_num>\n", argv[0]);
        return 1;
    }
    int c = atoi(argv[1]);
    int32_t res = 0;
    miniaudio_player_t *player = miniaudio_player_create(NULL, &res);
    assert(player != NULL);

    if (c == 1)
    {
        printf("Testing non-existent file...\n");
        miniaudio_player_open_file(player, "/tmp/this_file_does_not_exist_at_all.wav");
    }
    else if (c == 2)
    {
        printf("Testing empty file...\n");
        FILE *f = fopen("/tmp/empty.wav", "wb");
        fclose(f);
        miniaudio_player_open_file(player, "/tmp/empty.wav");
        unlink("/tmp/empty.wav");
    }
    else if (c == 3)
    {
        printf("Testing corrupt file...\n");
        FILE *f = fopen("/tmp/corrupt.wav", "wb");
        char b[512] = {0};
        fwrite(b, 1, 512, f);
        fclose(f);
        miniaudio_player_open_file(player, "/tmp/corrupt.wav");
        unlink("/tmp/corrupt.wav");
    }
    else if (c == 4)
    {
        printf("Testing directory...\n");
        miniaudio_player_open_file(player, "/tmp");
    }

    /* Give worker thread a moment to hit the race condition if present */
    usleep(50000);
    miniaudio_player_destroy(player);
    printf("Done case %d\n", c);
    return 0;
}
