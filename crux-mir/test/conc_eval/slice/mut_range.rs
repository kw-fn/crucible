// FAIL: projection [::ops::index::Index::Output<[u8],::ops::range::RangeFrom<usize>>] with unknown translation
fn g(xs: &mut [u8]) {
    xs[0] = xs[0] + 1;
}

fn f(x: u8) -> u8 {
    let mut xs = [x; 4];
    let y = g(&mut xs[1..]);
    xs[1]
}

const ARG: u8 = 42;

#[cfg(with_main)]
fn main() {
    println!("{:?}", f(ARG))
}
